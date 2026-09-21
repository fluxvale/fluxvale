defmodule FluxVale.Seeds.CatalogData do
  @moduledoc """
  Declarative catalog seed data, loaded from `priv/repo/seeds/catalog_data.yaml`.

  Adding a catalog app is purely additive: append a YAML entry. The seed
  runner (`FluxVale.Seeds.seed_catalog!/0`) get-or-creates each record, so
  re-running converges to the YAML with zero dupes.

  Type normalization (YAML is lossy vs Elixir literals):

    * `default_cpu_cores` — quoted string (`"0.5"`) to avoid float
      precision loss; converted to `Decimal` here.
    * `published_at` — ISO 8601 string; parsed to `DateTime`.

  Env-var specs (`configurable_env_vars`) are **not** validated here — the
  resource's `EnvVarSchema` type rejects malformed specs at write time, one
  enforcement point for seeds, AshAdmin, and the future API alike (v1
  validated only in this loader).
  """

  @spec entries :: [map()]
  def entries, do: entries(default_path())

  @doc """
  Parses catalog entries from a specific YAML file — the 1-arity exists so
  normalization is testable against fixture YAML without touching the real
  seed data.
  """
  @spec entries(Path.t()) :: [map()]
  def entries(path) do
    path
    |> File.read!()
    |> YamlElixir.read_from_string!()
    |> Enum.map(&normalize_entry/1)
  end

  defp default_path do
    :flux_vale
    |> :code.priv_dir()
    |> Path.join("repo/seeds/catalog_data.yaml")
  end

  defp normalize_entry(%{"category" => category, "apps" => apps}) do
    %{
      category: normalize_category(category),
      apps: Enum.map(apps, &normalize_app/1)
    }
  end

  defp normalize_category(%{"name" => name, "slug" => slug, "description" => description}) do
    %{name: name, slug: slug, description: description}
  end

  defp normalize_app(app) do
    %{
      name: app["name"],
      slug: app["slug"],
      tagline: app["tagline"],
      description: app["description"],
      icon_url: app["icon_url"],
      source_url: app["source_url"],
      docs_url: app["docs_url"],
      versions: Enum.map(app["versions"], &normalize_version/1)
    }
  end

  defp normalize_version(version) do
    %{
      version: version["version"],
      image: version["image"],
      port: version["port"],
      default_env_vars: Map.get(version, "default_env_vars", %{}),
      configurable_env_vars: Map.get(version, "configurable_env_vars", %{}),
      default_cpu_cores: Decimal.new(version["default_cpu_cores"]),
      default_memory_mb: version["default_memory_mb"],
      default_storage_gb: version["default_storage_gb"],
      release_notes: version["release_notes"],
      published_at: parse_datetime!(version["published_at"])
    }
  end

  defp parse_datetime!(iso8601_string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601_string)
    datetime
  end
end
