defmodule FluxVale.Identity.Operations.VerifyAuthCode do
  @moduledoc """
  Verifies a one-time login code
  ([ADR-0003](../../../../../../docs/adr/00003-ashauthentication-drop-authentik.md),
  #21): single-use consumption
  (the optimistic-locked delete is the arbiter), capped attempts enforced
  atomically at the database, JIT provisioning on first sign-in, and the
  standard 60-day session mint on success.
  """

  import Ash.Changeset, only: [for_create: 3, for_update: 2, for_destroy: 2]
  import Ash.Query, only: [for_read: 3, sort: 2]

  alias FluxVale.Identity.AuthCode
  alias FluxVale.Identity.User

  # The framework's own door for auth flows — see RequestAuthCode's note
  @interaction %{private: %{ash_authentication?: true}}

  @doc """
  Verifies `code` for `email`. On success returns `{:ok, user, token}`;
  failures are uniform in shape — no account-enumeration signal between
  an unknown address and a bad code.
  """
  @spec call(String.t() | Ash.CiString.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, atom()}
  def call(email, code) do
    # Guards can't call remote functions — bind the cap first
    max_attempts = AuthCode.max_attempts()

    case latest_active_code(email) do
      nil ->
        {:error, :no_active_code}

      %AuthCode{attempts: attempts} = _exhausted when attempts >= max_attempts ->
        # The cap is the backoff: an exhausted code forces a resend, and
        # resends are throttled — escalating time-out by construction
        {:error, :locked_out}

      %AuthCode{} = auth_code ->
        attempt_verify(auth_code, email, code)
    end
  end

  defp latest_active_code(email) do
    email
    |> active_codes()
    |> List.first()
  end

  defp active_codes(email) do
    AuthCode
    |> for_read(:active_for_email, %{email: email})
    |> sort(created_at: :desc)
    |> Ash.Query.set_context(@interaction)
    |> Ash.read!()
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
    case lookup_user(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> provision_user(email)
    end
  end

  defp lookup_user(email) do
    result =
      User
      |> for_read(:get_by_email, %{email: email})
      |> Ash.Query.set_context(@interaction)
      |> Ash.read()

    case result do
      {:ok, [user]} -> {:ok, user}
      {:ok, []} -> {:error, :not_found}
      # Infra failure propagates a defined shape instead of raising a
      # CaseClauseError AFTER the code was consumed (review finding)
      {:error, _read_failed} -> {:error, :user_lookup_failed}
    end
  end

  # JIT provisioning (ADR-0003): a valid code proves inbox ownership
  defp provision_user(email) do
    User
    |> for_create(:create, %{email: email})
    |> Ash.Changeset.set_context(@interaction)
    |> Ash.create()
  end
end
