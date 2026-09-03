defmodule FluxVale.Identity.Operations do
  @moduledoc """
  Identity operations: the passwordless email-code flow (ADR-0003, #21).

  Server-owned secrets throughout: `request_auth_code/1` stores only a
  bcrypt hash, and `verify_auth_code/2` is the sole consumer. All reads
  and writes run under AshAuthentication's private interaction context —
  the framework's own door for auth flows
  (`AshAuthentication.Checks.AshAuthenticationInteraction`) — set on the
  changeset/query exactly as the framework sets it, so policies stay live
  for everything that is not an authentication interaction.
  """

  import Ash.Changeset, only: [for_create: 3, for_update: 2, for_destroy: 2]
  import Ash.Query, only: [for_read: 3, sort: 2]

  alias FluxVale.Identity.AuthCode
  alias FluxVale.Identity.User
  alias FluxVale.Mailer
  require Logger

  # ADR-0003 constraints, as code:
  @code_digits 6
  @ttl_minutes 10
  @max_attempts 5
  @resend_throttle_seconds 60
  @bcrypt_log_rounds 10

  @interaction %{private: %{ash_authentication?: true}}

  # ── request ────────────────────────────────────────────────────────────

  @doc """
  Issues a 6-digit code to `email` and sends it. Throttled to one send
  per #{@resend_throttle_seconds}s per address (the ADR-0003
  send-endpoint throttle).

  `deliver/2` is injectable for the delivery-failure path (review
  finding): if delivery fails, the stored code is burned so the user
  isn't locked out of retrying by a code they never received.
  """
  @spec request_auth_code(String.t() | Ash.CiString.t(), function()) ::
          :ok | {:error, :throttled | :delivery_failed}
  def request_auth_code(email, deliver \\ &Mailer.deliver_auth_code/2) do
    with :ok <- throttle_check(email) do
      code = random_code()
      {:ok, auth_code} = store_code(email, code)

      recipient = to_string(email)

      case deliver.(recipient, code) do
        {:ok, _receipt} ->
          :ok

        {:error, _reason} ->
          # Never leave a live code the user never received — it would
          # block retries for the throttle window (review finding)
          burn(auth_code)
          {:error, :delivery_failed}
      end
    end
  end

  defp throttle_check(email) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@resend_throttle_seconds, :second)

    recent_count =
      email
      |> active_codes()
      |> Enum.count(&DateTime.after?(&1.created_at, cutoff))

    if recent_count > 0, do: {:error, :throttled}, else: :ok
  end

  defp active_codes(email) do
    AuthCode
    |> for_read(:active_for_email, %{email: email})
    |> sort(created_at: :desc)
    |> Ash.Query.set_context(@interaction)
    |> Ash.read!()
  end

  defp store_code(email, code) do
    AuthCode
    |> for_create(:create, %{
      email: email,
      code_hash: Bcrypt.hash_pwd_salt(code, log_rounds: @bcrypt_log_rounds),
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_minutes, :minute)
    })
    |> Ash.Changeset.set_context(@interaction)
    |> Ash.create()
  end

  defp random_code do
    8
    |> :crypto.strong_rand_bytes()
    |> :binary.decode_unsigned()
    |> rem(10 ** @code_digits)
    |> Integer.to_string()
    |> String.pad_leading(@code_digits, "0")
  end

  # ── verify ─────────────────────────────────────────────────────────────

  @doc """
  Verifies `code` for `email`. On success: burns the code (single-use),
  JIT-provisions the account on first sign-in, and mints the standard
  60-day session token. Returns `{:ok, user, token}`.

  Failures return `{:error, atom()}` uniform in shape to the caller —
  no account-enumeration signal between an unknown address and a bad code.
  """
  @spec verify_auth_code(String.t() | Ash.CiString.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, atom()}
  def verify_auth_code(email, code) do
    case active_codes(email) do
      [] ->
        {:error, :no_active_code}

      [%AuthCode{attempts: attempts} | _older] when attempts >= @max_attempts ->
        # The cap is the backoff: an exhausted code forces a resend, and
        # resends are throttled — escalating time-out by construction.
        {:error, :locked_out}

      [auth_code | _older] ->
        attempt_verify(auth_code, email, code)
    end
  end

  defp attempt_verify(auth_code, email, code) do
    if Bcrypt.verify_pass(code, auth_code.code_hash) do
      consume_and_mint(auth_code, email)
    else
      register_wrong_attempt(auth_code)
    end
  end

  # The burn is the arbiter (optimistic lock on the resource): only the
  # request that actually consumed the code mints a session — the TOCTOU
  # loser gets a clean failure (review finding: CWE-367)
  defp consume_and_mint(auth_code, email) do
    case burn(auth_code) do
      :ok ->
        with {:ok, user} <- ensure_user(email),
             {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user) do
          Logger.info("auth code verified for #{email}")
          {:ok, user, token}
        end

      {:error, _lost_the_race} ->
        {:error, :no_active_code}
    end
  end

  defp register_wrong_attempt(auth_code) do
    result =
      auth_code
      |> for_update(:register_attempt)
      |> Ash.Changeset.set_context(@interaction)
      |> Ash.update()

    case result do
      {:ok, _row} -> {:error, :wrong_code}
      # The atomic cap guard refused the increment (review: CWE-307)
      {:error, _at_cap} -> {:error, :locked_out}
    end
  end

  defp burn(auth_code) do
    auth_code
    |> for_destroy(:burn)
    |> Ash.Changeset.set_context(@interaction)
    |> Ash.destroy()
  end

  defp ensure_user(email) do
    User
    |> for_read(:get_by_email, %{email: email})
    |> Ash.Query.set_context(@interaction)
    |> Ash.read()
    |> ensure_user_after_lookup(email)
  end

  defp ensure_user_after_lookup({:ok, [user]}, _email), do: {:ok, user}

  # JIT provisioning (ADR-0003): a valid code proves inbox ownership
  defp ensure_user_after_lookup({:ok, []}, email) do
    User
    |> for_create(:create, %{email: email})
    |> Ash.Changeset.set_context(@interaction)
    |> Ash.create()
  end
end
