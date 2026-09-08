defmodule FluxVale.Ops.AccessRules.BustCache do
  @moduledoc """
  Resource change: force-refresh the AccessRules snapshot after every
  AccessRule mutation (settled on #26) — the mutating node sees its own
  change with no TTL wait; the TTL only bounds staleness on other nodes
  (ADR-0023 Am. 1). Runs for create, update, and destroy alike — removal
  is exactly the severing case.
  """

  use Ash.Resource.Change

  alias FluxVale.Ops.AccessRules.Cache

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, result ->
      :ok = Cache.refresh()
      {:ok, result}
    end)
  end
end
