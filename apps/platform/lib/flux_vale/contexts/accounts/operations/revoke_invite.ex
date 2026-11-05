defmodule FluxVale.Accounts.Operations.RevokeInvite do
  @moduledoc """
  The owner's retirement of an invitation (slice 4 of #408): stamps
  `revoked_at` (idempotent — a second call keeps the original stamp)
  and frees the address for a re-invite. The revoke action's owner
  policy is the gate; this seam just names it.
  """

  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Identity.User

  @spec call(User.t(), MembershipInvite.t()) ::
          {:ok, MembershipInvite.t()} | {:error, term()}
  def call(%User{} = owner, %MembershipInvite{} = invite) do
    MembershipInvite.revoke(invite, actor: owner)
  end
end
