defmodule FluxVale.Ops.AccessRules.BustCache do
  @moduledoc """
  Resource change: refresh the AccessRules snapshot after every AccessRule
  mutation (settled on #26) — the mutating node sees its own change with
  no TTL wait; the TTL only bounds staleness on other nodes (ADR-0023
  Am. 1). Runs for create, update, and destroy alike — removal is exactly
  the severing case.

  The refresh read happens in the mutating process inside the mutation's
  transaction (it sees its own change). Ordering against other refreshes
  is the Cache's job: every read is stamped at start, and a store whose
  stamp isn't newer than the held one is discarded — an older overlapping
  refresh landing last cannot overwrite a newer snapshot (CodeRabbit,
  #48). `after_transaction` would read post-commit but is not honored
  from module changes on the bulk path (verified on dev: never fires) —
  the residual window (two concurrent mutations whose pre-commit reads
  interleave) is documented in `AccessRules.Cache` and bounded by the TTL.
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
