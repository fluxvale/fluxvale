defmodule FluxVale.Catalog.App.CastIconPath do
  @moduledoc """
  The write gate for `App.icon_url` (#718): casts every changed value
  through `Types.IconPath`, so seeds, AshAdmin, and the API share the
  one contract.

  The attribute itself stays `:string`: `ash_json_api` 1.7.1 matches
  filter operators against the raw attribute type, and a NewType there
  silently drops the string predicates (`contains`, `like`, `ilike`,
  `string_starts_with`, ...) from the public filter schema. Keeping
  the stored type a string keeps the wire contract intact while the
  change runs the same validation the type owns.

  The raw params are checked ahead of the cast attributes for a changed
  value supplied in params: `:string` trims before a change sees the
  value, so a padded path is rejected from what the caller sent. A
  programmatic `change_attribute`/`force_change_attribute` reaches only
  the trimmed fallback, and a padded value equal to the current value
  is dropped as a no-op; both store a safe, trimmed path.
  """

  use Ash.Resource.Change

  alias FluxVale.Catalog.Types.IconPath

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :icon_url) do
      :error -> changeset
      {:ok, cast} -> validate(changeset, raw_icon_url(changeset, cast))
    end
  end

  # String keys are legal input too (YAML, JSON:API); the cast value is
  # the fallback for a change set programmatically rather than by params.
  defp raw_icon_url(changeset, fallback) do
    params = changeset.params
    Map.get(params, :icon_url, Map.get(params, "icon_url", fallback))
  end

  defp validate(changeset, value) do
    case IconPath.cast_input(value, []) do
      {:ok, cast} -> Ash.Changeset.change_attribute(changeset, :icon_url, cast)
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :icon_url, message: message)
    end
  end
end
