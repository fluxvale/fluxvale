defmodule FluxVale.Identity.Operations.RequestAuthCode do
  @moduledoc """
  Issues and delivers a one-time login code
  ([ADR-0003](../../../../../../docs/adr/00003-ashauthentication-drop-authentik.md),
  #21).

  Server-owned secret throughout: only a bcrypt hash is stored, and a
  delivery failure burns the stored code — a code the user never
  received must not block retries for the throttle window.
  """

  alias FluxVale.Identity.AuthCode
  alias FluxVale.Mailer
  alias FluxVale.Ops.AccessRules

  @code_digits 6
  @ttl_minutes 10
  @resend_throttle_seconds 60
  @bcrypt_log_rounds 10

  # The framework's own door for auth flows — the same private context
  # AshAuthentication sets on its internal interactions, so policies
  # stay live for everything that is not an authentication interaction
  @interaction %{private: %{ash_authentication?: true}}

  @doc """
  Issues a #{@code_digits}-digit code to `email`. Throttled to one send
  per #{@resend_throttle_seconds}s per address (the ADR-0003
  send-endpoint throttle).

  `deliver/2` is injectable for the delivery-failure path.
  """
  @spec call(String.t() | Ash.CiString.t(), function()) ::
          :ok | {:error, :throttled | :delivery_failed | :not_allowed}
  def call(email, deliver \\ &Mailer.deliver_auth_code/2) do
    with :ok <- access_gate(email),
         :ok <- throttle_check(email) do
      code = random_code()
      {:ok, auth_code} = store_code(email, code)
      recipient = to_string(email)

      case deliver.(recipient, code) do
        {:ok, _receipt} ->
          :ok

        {:error, _reason} ->
          # Best-effort cleanup: a failed burn (e.g. racing attempts
          # change) leaves the row to expire; the user's retry lands on
          # the throttle message, which is bounded and honest (review)
          _result = burn(auth_code)
          {:error, :delivery_failed}
      end
    end
  end

  defp access_gate(email) do
    if AccessRules.allowed?(email), do: :ok, else: {:error, :not_allowed}
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
    |> Ash.Query.for_read(:active_for_email, %{email: email})
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.set_context(@interaction)
    |> Ash.read!()
  end

  defp store_code(email, code) do
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_minutes, :minute)

    AuthCode
    |> Ash.Changeset.for_create(:create, %{
      email: email,
      code_hash: Bcrypt.hash_pwd_salt(code, log_rounds: @bcrypt_log_rounds),
      expires_at: expires_at
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

  defp burn(auth_code) do
    auth_code
    |> Ash.Changeset.for_destroy(:burn)
    |> Ash.Changeset.set_context(@interaction)
    |> Ash.destroy()
  end
end
