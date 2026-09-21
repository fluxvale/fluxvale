defmodule FluxVale.Seeds do
  @moduledoc """
  Seed runner, callable from `priv/repo/seeds.exs` (dev, `mix setup`) and
  tests. No prod caller yet — prod catalog bring-up is settled with the
  fleet repo (M4).

  Get-or-create rather than `Ash.Seed.seed!/2` + `upsert_identity`: Ash
  validates **all** identities before reaching the DB upsert, so the
  unique-name constraint fails even when upserting by slug. Lookup-then-
  create is the reliable idempotent shape (v1 lesson, ported).

  Every call runs `authorize?: false` — bootstrap: there is no actor to
  authorize before seed data exists (same posture as the admin seed).
  """

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Seeds.CatalogData

  require Ash.Query

  @doc """
  Seeds catalog Categories, Apps, and AppVersions from `CatalogData`.

  Idempotent — records are looked up by slug (Category, App) or app_id +
  version (AppVersion); existing rows are updated to the seed attrs, so
  re-running converges the whole catalog to catalog_data.yaml. Slug and
  version are the lookup keys and immutable on update — renaming in the
  YAML orphans the old row rather than converging it.
  """
  @spec seed_catalog! :: :ok
  def seed_catalog! do
    for %{category: cat_attrs, apps: apps} <- CatalogData.entries() do
      category = seed_category!(cat_attrs)
      seed_apps!(apps, category)
    end

    :ok
  end

  defp seed_apps!(apps, category) do
    for app_entry <- apps do
      {versions, app_attrs} = Map.pop!(app_entry, :versions)
      app = seed_app!(Map.put(app_attrs, :category_id, category.id))

      for version_attrs <- versions do
        seed_app_version!(Map.put(version_attrs, :app_id, app.id))
      end
    end

    :ok
  end

  defp seed_category!(attrs) do
    case Category.get_by_slug(attrs.slug, authorize?: false) do
      {:ok, category} ->
        # slug is the lookup key — immutable on update (see the resource).
        Category.update!(category, Map.drop(attrs, [:slug]), authorize?: false)

      {:error, _not_found} ->
        Category.create!(attrs, authorize?: false)
    end
  end

  defp seed_app!(attrs) do
    case App.get_by_slug(attrs.slug, authorize?: false) do
      {:ok, app} ->
        App.update!(app, Map.drop(attrs, [:slug]), authorize?: false)

      {:error, _not_found} ->
        App.create!(attrs, authorize?: false)
    end
  end

  defp seed_app_version!(attrs) do
    # No slug to look up by — filter the read by app_id + version to detect
    # an existing row; when present, update it with the seed attrs so the
    # seed converges instead of no-op'ing on drifted data.
    existing =
      AppVersion
      |> Ash.Query.filter(app_id == ^attrs.app_id and version == ^attrs.version)
      |> Ash.read!(authorize?: false)

    case existing do
      [version] ->
        # version is the lookup key (with app_id) — immutable on update
        # (see the resource), so it's dropped from the update attrs.
        AppVersion.update!(version, Map.drop(attrs, [:app_id, :version]), authorize?: false)

      [] ->
        AppVersion.create!(attrs, authorize?: false)

      # Defensive: unique_version_per_app prevents this; only fires on data
      # drift / schema corruption.
      multiples ->
        raise """
        seed_app_version!/1 expected 0 or 1 existing AppVersion rows for
        app_id=#{inspect(attrs.app_id)} version=#{inspect(attrs.version)},
        got #{length(multiples)}. Possible data drift on the unique_version_per_app identity.
        """
    end
  end
end
