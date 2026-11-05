defmodule FluxVale.Accounts.Operations.DeclineInvite do
  @moduledoc """
  The invitee's no (slice 4 of #408): the raw token retires the invite
  (`revoked_at` stamped) and no membership is ever written. Same
  token-path posture as accept — the token is the bearer credential,
  the decline action's open-gate filter is the race arbiter.
  """

  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Accounts.Operations.ResolveInvite

  @spec call(term()) :: {:ok, MembershipInvite.t()} | {:error, term()}
  def call(raw_token) do
    case ResolveInvite.call(raw_token) do
      {:ok, {:open, invite}} -> MembershipInvite.decline(invite, authorize?: false)
      # Nothing may retire an invite something already happened to.
      {:ok, _terminal} -> {:error, :not_open}
      {:error, :unknown_token} = unknown -> unknown
    end
  end
end
