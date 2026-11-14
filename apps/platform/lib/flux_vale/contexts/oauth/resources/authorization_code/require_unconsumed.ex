defmodule FluxVale.OAuth.AuthorizationCode.RequireUnconsumed do
  @moduledoc """
  The single-use guard (#766): pins `consumed_at IS NULL` into the
  UPDATE itself, so two concurrent exchanges race on one row and the
  loser gets a stale-record refusal instead of a second token pair.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(is_nil(consumed_at)))
  end
end
