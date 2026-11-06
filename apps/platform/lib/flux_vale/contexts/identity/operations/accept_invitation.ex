defmodule FluxVale.Identity.Operations.AcceptInvitation do
  @moduledoc """
  Consumes the one-time accept link (#502): the token resolves the
  pre-provisioned account, the :accept_invite write stamps acceptance
  and runs the first-login bootstrap (username, personal org, the
  verified mirror row — acceptance is the inbox proof), then the
  AccessRule gate and the session mint follow — the invitee is logged
  in straight away.

  The token IS the credential: the lookup and the consume write run
  system-side (`authorize?: false`, the MembershipInvite :accept
  posture — no actor exists yet, the session mints after the write).
  """

  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRules

  @doc """
  Accepts the invitation carried by `raw_token` and mints the session.
  Failures are atoms: :unknown_token, :already_accepted, :withdrawn,
  :expired, :unavailable (raced between read and write), :lookup_failed
  (DB), :not_allowed.
  """
  @spec call(String.t()) :: {:ok, User.t(), String.t()} | {:error, atom()}
  def call(raw_token) do
    with {:ok, user} <- resolve(raw_token),
         {:ok, user} <- consume(user),
         :ok <- AccessRules.ensure_allowed_user(user) do
      mint_session(user)
    end
  end

  defp resolve(raw_token) do
    hash = User.token_hash(raw_token)

    case fetch_user_by_hash(hash) do
      {:ok, nil} ->
        {:error, :unknown_token}

      {:ok, user} ->
        state_verdict(user)

      # coveralls-ignore-start - DB read failure mid-accept: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} ->
        {:error, :lookup_failed}
        # coveralls-ignore-stop
    end
  end

  defp fetch_user_by_hash(hash) do
    User
    |> Ash.Query.for_read(:get_by_invite_token_hash, %{token_hash: hash})
    |> Ash.read_one(authorize?: false)
  end

  # The pre-read verdict — the :accept_invite write's WHERE filter is
  # the true arbiter, this returns the friendly atom early (the
  # MembershipInvite resolve posture). :none with a resolvable hash is
  # structurally impossible — the hash is only ever written alongside
  # invited_at (:invite/:reinvite) — so a hand-built row is the only
  # writer that could reach it, and :unknown_token is the honest answer.
  defp state_verdict(user) do
    case user.invite_state do
      :accepted -> {:error, :already_accepted}
      :withdrawn -> {:error, :withdrawn}
      :expired -> {:error, :expired}
      :none -> {:error, :unknown_token}
      :pending -> {:ok, user}
    end
  end

  # The one-time consume: :accept_invite's WHERE filter arbitrates — a
  # second use, or a race against withdrawal or expiry between the read
  # above and this write, matches zero rows and refuses with
  # StaleRecord. authorize?: false — the token is the credential; no
  # actor exists yet.
  defp consume(user) do
    changeset = Ash.Changeset.for_update(user, :accept_invite, %{}, authorize?: false)

    case Ash.update(changeset) do
      {:ok, accepted} ->
        {:ok, accepted}

      # coveralls-ignore-start - race-only: the pre-read verdict catches
      # every sequential state (:withdrawn, :expired, :accepted), so
      # zero rows matching the consume filter needs a commit between the
      # read above and this write — true concurrency
      {:error, _raced_or_refused} ->
        {:error, :unavailable}
        # coveralls-ignore-stop
    end
  end

  # The session mint (the VerifyAuthCode posture): the with propagates
  # token_for_user's error shape untouched.
  defp mint_session(user) do
    with {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user) do
      # The signup-success point (business telemetry): one semantic
      # event with two fire sites — the JIT signup twin in
      # VerifyAuthCode; the listener is FluxValeWeb.Telemetry.
      :telemetry.execute(FluxVale.Identity.signup_event(), %{count: 1}, %{})

      {:ok, user, token}
    end
  end
end
