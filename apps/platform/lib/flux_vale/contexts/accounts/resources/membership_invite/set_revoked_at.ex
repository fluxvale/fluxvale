defmodule FluxVale.Accounts.MembershipInvite.SetRevokedAt do
  @moduledoc """
  Stamps `revoked_at` — idempotently (#360's PAT shape): a second
  revoke keeps the original stamp, so the recorded retirement moment
  never moves and callers may retry freely.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :revoked_at)) do
      Ash.Changeset.change_attribute(changeset, :revoked_at, DateTime.utc_now())
    else
      # Already retired: no change at all — the action succeeds as a
      # no-op, which is the idempotency contract.
      changeset
    end
  end
end
