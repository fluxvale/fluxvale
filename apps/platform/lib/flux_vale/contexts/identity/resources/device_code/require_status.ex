defmodule FluxVale.Identity.DeviceCode.RequireStatus do
  @moduledoc """
  A guarded transition's WHERE clause (#362 T3): pins the expected
  `status` into the UPDATE itself via `Ash.Changeset.filter/2`, so a
  row that moved between the caller's read and this write matches
  zero rows and the write fails (the StaleRecord shape) — the
  race-window answer that holds for system callers too (`authorize?:
  false` runs no policies, so a policy-expression guard would never
  see them; the changeset filter is the layer that does).
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, opts, _context) do
    status = opts[:status]
    Ash.Changeset.filter(changeset, expr(status == ^status))
  end
end
