defmodule FluxVale.Seeds.CatalogData do
  @moduledoc """
  Declarative catalog seed data, loaded from `priv/repo/seeds/catalog_data.yaml`.

  The shipped file carries Forgejo (#71, ADR-0031 M3) — the org's own git
  forge, dogfooded from day one. Kavita (v1's seed) was dropped: a library
  app needs file access, and SFTP is deferred post-beta (OQ #6).

  Adding a catalog app is purely additive: append a YAML entry. The seed
  runner (`FluxVale.Seeds.seed_catalog!/0`) looks each record up by its
  key (slug, or app_id + version) and updates it to match the YAML, so
  re-running converges with zero dupes.

  Type normalization (YAML is lossy vs Elixir literals):

    * `default_cpu_cores` — quoted string (`"0.5"`) to avoid float
      precision loss; converted to `Decimal` here.
    * `published_at` — ISO 8601 string; parsed to `DateTime`.

  Optional fields mirror the resource defaults: `healthcheck_path` "/",
  `default_cpu_cores` "0.5", `default_memory_mb` 256, `default_storage_gb` 0,
  `published_at` nil, env maps `%{}`.

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
    contents = File.read!(path)
    parsed = YamlElixir.read_from_string!(contents)

    case parsed do
      entries when is_list(entries) ->
        Enum.map(entries, &normalize_entry/1)

      # Empty/comments-only file parses to nil or %{} — a deliberately
      # empty catalog is valid (the machinery tolerates it).
      _empty ->
        []
    end
  end

  defp default_path do
    :flux_vale
    |> :code.priv_dir()
    |> Path.join("repo/seeds/catalog_data.yaml")
  end

  defp normalize_entry(%{"category" => category, "apps" => apps})
       when is_list(apps) do
    %{
      category: normalize_category(category),
      apps: Enum.map(apps, &normalize_app/1)
    }
  end

  # coveralls-ignore-start - YAML seed validation; fires at seed time on a
  # hand-edited catalog file, not on any runtime path
  defp normalize_entry(%{"category" => category}) do
    raise "catalog seed: category #{inspect(category["slug"])} must have an apps list"
  end

  # coveralls-ignore-stop

  defp normalize_category(%{"name" => name, "slug" => slug, "description" => description}) do
    %{name: name, slug: slug, description: description}
  end

  defp normalize_app(app) do
    case Map.get(app, "versions") do
      versions when is_list(versions) and versions != [] ->
        %{
          name: app["name"],
          slug: app["slug"],
          tagline: app["tagline"],
          description: app["description"],
          icon_url: app["icon_url"],
          source_url: app["source_url"],
          docs_url: app["docs_url"],
          versions: Enum.map(versions, &normalize_version/1)
        }

      other ->
        raise "catalog seed: app #{inspect(app["slug"])} must have a non-empty versions list, got: #{inspect(other)}"
    end
  end

  defp normalize_version(version) do
    %{
      version: version["version"],
      image: version["image"],
      port: version["port"],
      healthcheck_path: Map.get(version, "healthcheck_path", "/"),
      default_env_vars: Map.get(version, "default_env_vars", %{}),
      configurable_env_vars: Map.get(version, "configurable_env_vars", %{}),
      default_cpu_cores: cpu_cores(version),
      default_memory_mb: Map.get(version, "default_memory_mb", 256),
      default_storage_gb: Map.get(version, "default_storage_gb", 0),
      release_notes: version["release_notes"],
      published_at: published_at(version)
    }
  end

  defp cpu_cores(version) do
    # Quoted string in YAML ("0.5") to avoid float precision loss.
    default_cores = Map.get(version, "default_cpu_cores", "0.5")
    Decimal.new(default_cores)
  end

  defp published_at(version) do
    case Map.get(version, "published_at") do
      nil -> nil
      iso8601_string -> parse_datetime!(iso8601_string)
    end
  end

  defp parse_datetime!(iso8601_string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601_string)
    datetime
  end
end
