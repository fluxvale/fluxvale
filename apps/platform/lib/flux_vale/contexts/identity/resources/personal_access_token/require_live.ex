defmodule FluxVale.Identity.PersonalAccessToken.RequireLive do
  @moduledoc """
  The conditional-revoke guard (#766): pins `revoked_at IS NULL` into
  the UPDATE so two concurrent refresh rotations race on one row and
  the loser gets a stale-record refusal — the reuse signal the refresh
  grant turns into a family revocation.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(is_nil(revoked_at)))
  end
end
