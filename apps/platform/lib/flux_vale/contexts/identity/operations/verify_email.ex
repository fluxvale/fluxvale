defmodule FluxVale.Identity.Operations.VerifyEmail do
  @moduledoc """
  The actor verifies one of their pending addresses with the code that
  landed in its inbox (#285 T3): the same lookups and burn semantics as
  sign-in (latest live code for the address, capped attempts, single-use
  optimistic burn) — a live code for the address IS the inbox proof —
  then the internal `mark_verified` stamps the row.
  """

  alias FluxVale.Identity.AuthCode
  alias FluxVale.Identity.UserEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  # The auth-code store's own door — the same private context the
  # sign-in ops set (AuthCode is an AshAuthentication strategy surface;
  # UserEmail is not, and gets none of this).
  @interaction %{private: %{ash_authentication?: true}}

  @doc """
  Verifies `code` against the actor's pending row `email_row_id`.

  Row failures: `:not_found` (no such row among the actor's — another
  user's row id is indistinguishable from a bogus one), `:not_pending`
  (already verified). Code failures mirror sign-in: `:no_active_code`,
  `:wrong_code`, `:locked_out`.
  """
  @spec call(term(), Ash.UUID.t(), String.t()) :: {:ok, UserEmail.t()} | {:error, atom()}
  def call(actor, email_row_id, code) do
    with {:ok, row} <- pending_row(actor, email_row_id),
         :ok <- verify_code(row.address, code) do
      stamp_verified(row)
    end
  end

  # :mine is the owner-scoped read — the actor's rows only, so a
  # stranger's row id reads as not_found, never as someone else's row.
  defp pending_row(actor, email_row_id) do
    outcome =
      UserEmail
      |> Ash.Query.for_read(:mine, %{}, actor: actor)
      |> Ash.Query.filter(id == ^email_row_id)
      |> Ash.read()

    case outcome do
      {:ok, [%{verified_at: nil} = row]} ->
        {:ok, row}

      {:ok, [%{verified_at: %DateTime{}}]} ->
        {:error, :not_pending}

      {:ok, []} ->
        {:error, :not_found}

      # Infra failure propagates a defined shape instead of raising after
      # the code was burned (same posture as VerifyAuthCode's lookup)
      # coveralls-ignore-start - DB read failure mid-verify: not
      # simulatable under the sandbox
      {:error, _read_failed} ->
        {:error, :row_lookup_failed}
        # coveralls-ignore-stop
    end
  end

  # Guards can't call remote functions — bind the cap first
  defp verify_code(address, code) do
    max_attempts = AuthCode.max_attempts()

    case latest_active_code(address) do
      nil ->
        {:error, :no_active_code}

      %AuthCode{attempts: attempts} when attempts >= max_attempts ->
        # The cap is the backoff, as in sign-in: an exhausted code forces
        # a fresh request, and requests are throttled
        {:error, :locked_out}

      %AuthCode{} = auth_code ->
        attempt(auth_code, code)
    end
  end

  defp latest_active_code(address) do
    address
    |> active_codes()
    |> List.first()
  end

  defp active_codes(address) do
    AuthCode
    |> Ash.Query.for_read(:active_for_email, %{email: address})
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.set_context(@interaction)
    |> Ash.read!()
  end

  defp attempt(auth_code, code) do
    if Bcrypt.verify_pass(code, auth_code.code_hash) do
      burn(auth_code)
    else
      register_wrong_attempt(auth_code)
    end
  end

  # The burn is the arbiter (optimistic lock), exactly as in sign-in:
  # the loser of a race burns nothing and stamps nothing
  defp burn(auth_code) do
    case destroy(auth_code) do
      :ok ->
        :ok

      # coveralls-ignore-start - TOCTOU loser arm: needs the code burned
      # between fetch and burn — true concurrency, not sequential
      {:error, _lost_the_race} ->
        {:error, :no_active_code}
        # coveralls-ignore-stop
    end
  end

  defp register_wrong_attempt(auth_code) do
    result =
      auth_code
      |> Ash.Changeset.for_update(:register_attempt)
      |> Ash.Changeset.set_context(@interaction)
      |> Ash.update()

    case result do
      {:ok, _row} ->
        {:error, :wrong_code}

      # The atomic cap guard refused the increment (race-only: the
      # pre-check catches the cap first in any sequential flow)
      # coveralls-ignore-start
      {:error, _at_cap} ->
        {:error, :locked_out}
        # coveralls-ignore-stop
    end
  end

  defp destroy(auth_code) do
    outcome =
      auth_code
      |> Ash.Changeset.for_destroy(:burn)
      |> Ash.Changeset.set_context(@interaction)
      |> Ash.destroy()

    case outcome do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # T1's designed internal path: the proof is the live code burned
  # above, not the actor — an owner stamping verified_at themselves
  # would hollow out every guard that reads it. Same posture as the
  # seeds; platform admins keep their own grant on the action.
  defp stamp_verified(row) do
    case UserEmail.mark_verified(row, authorize?: false) do
      {:ok, verified} ->
        {:ok, verified}

      # The row was removed between the burn and the stamp — nothing
      # left to verify (concurrency-only)
      # coveralls-ignore-start
      {:error, _gone} ->
        {:error, :not_found}
        # coveralls-ignore-stop
    end
  end
end
