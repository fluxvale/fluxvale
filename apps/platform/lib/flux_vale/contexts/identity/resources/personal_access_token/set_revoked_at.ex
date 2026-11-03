defmodule FluxVale.Identity.PersonalAccessToken.SetRevokedAt do
  @moduledoc """
  Stamps `revoked_at` — idempotently (#360): a second revoke keeps the
  original stamp, so the recorded sever moment never moves and callers
  may retry freely.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :revoked_at) do
      nil ->
        Ash.Changeset.change_attribute(changeset, :revoked_at, DateTime.utc_now())

      # Already revoked: no change at all — the action succeeds as a
      # no-op, which is the idempotency contract.
      _already_revoked ->
        changeset
    end
  end
end
