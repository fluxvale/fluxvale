defmodule FluxVale.Accounts.Organization.StaleFormGuard do
  @moduledoc """
  The rename flows' stale-form guard (#276): the write is filtered on
  the slug the caller loaded, so a view mounted before a rename fails
  with `StaleRecord` instead of silently writing the old address back.

  Lives on both rename actions — the panel's `:update` (name and slug)
  and the machine API's `:update_name` (name only) — so neither can
  drift. A function change keeps the actions non-atomic, which is what
  lets a simple policy check authorize the per-record stream (the
  bulk-update path `ash_json_api` drives).
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    case Map.get(changeset.data, :slug) do
      # Dead in practice, kept so a slug-less shape can never add a nil
      # filter: require_atomic?(false) keeps bulk :atomic strategies
      # out, and every changeset that runs carries the loaded row.
      # coveralls-ignore-next-line
      nil -> changeset
      loaded_slug -> Ash.Changeset.filter(changeset, slug: loaded_slug)
    end
  end
end
