defmodule FluxVale.Seeds.CatalogData do
  @moduledoc """
  Declarative catalog seed data, loaded from `priv/repo/seeds/catalog_data.yaml`.

  The shipped file carries Forgejo (#71, ADR-0031 M3) — the org's own git
  forge, dogfooded from day one. Kavita (#189) joined it: seeded anyway,
  because a deployed instance is claimable and its state persists on the
  volume; the library's file-ingest path is the separate #190 work.
  Pocket ID (#492) joined it: the passkey-first OIDC provider, and the
  first app whose upstream demands a deploy-time secret (its
  ENCRYPTION_KEY ships as the version's one required env input).
  ActualBudget (#492) joined it: the first-open-sets-password pattern
  (ADR-0034 Am. 1) landed with it, plus the forbidden-env lock that
  keeps user-injected env from triggering an OIDC self-claim ahead of
  the owner's first open.

  Adding a catalog app is purely additive: append a YAML entry. The seed
  runner (`FluxVale.Seeds.seed_catalog!/0`) looks each record up by its
  key (slug, or app_id + version) and updates it to match the YAML, so
  re-running converges with zero dupes.

  Type normalization (YAML is lossy vs Elixir literals):

    * `default_cpu_cores` — quoted string (`"0.5"`) to avoid float
      precision loss; converted to `Decimal` here.
    * `published_at` — ISO 8601 string; parsed to `DateTime`.

  Optional fields mirror the resource defaults: `healthcheck_path` "/",
  `storage_mount_path` "/data", `default_cpu_cores` "0.5",
  `default_memory_mb` 256, `default_storage_gb` 0, `published_at` nil,
  env maps `%{}`, `first_run` nil (no first-open posture needed — the
  contract is optional per app, #181), `oidc_wiring` nil (no automatic
  SSO wiring — the recipe is opt-in per version, #597),
  `backing_services` `[]` (no bundled services — the declaration is
  opt-in per version, #612). The #611
  marketing fields pass through raw the same way: absent lists
  (`caveats`, `alternatives`, `screenshots`, `features`, `faq`) load as
  `[]`, absent strings (`in_action_intro`, `community_url`, and
  `Category.audience`) as nil.

  `recommended_size` (the priced unit, #125) is **required** in the YAML —
  a version without one cannot be priced (ADR-0028). The loader only
  carries the slug through; the seed runner resolves it against the
  pricing_sizes table (seed_pricing!/1 runs first in seed/0).

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

  defp normalize_category(
         %{"name" => name, "slug" => slug, "description" => description} = category
       ) do
    %{
      name: name,
      slug: slug,
      description: description,
      # #611 (D5): the "who is this for" line, raw pass-through — the
      # attribute's length constraint owns validation at write time.
      audience: Map.get(category, "audience")
    }
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
          file_access: Map.get(app, "file_access", false),
          # Marketing metadata (#611 plan §4.4, S1): raw pass-through
          # for the seven app fields — the types and the attribute
          # constraints validate at write time, one enforcement point
          # (the first_run/oidc_wiring stance). Defaults mirror the
          # resource: absent lists are [], absent strings nil.
          caveats: Map.get(app, "caveats", []),
          alternatives: Map.get(app, "alternatives", []),
          in_action_intro: Map.get(app, "in_action_intro"),
          screenshots: Map.get(app, "screenshots", []),
          features: Map.get(app, "features", []),
          faq: Map.get(app, "faq", []),
          community_url: Map.get(app, "community_url"),
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
      storage_mount_path: Map.get(version, "storage_mount_path", "/data"),
      instance_url_env: version["instance_url_env"],
      # The OIDC callback path an identity provider needs at client
      # registration (#511) — raw pass-through like instance_url_env;
      # the attribute's match constraint owns validation at write time.
      oidc_callback_path: version["oidc_callback_path"],
      default_env_vars: Map.get(version, "default_env_vars", %{}),
      configurable_env_vars: Map.get(version, "configurable_env_vars", %{}),
      # First-run contract (#181, ADR-0034): raw pass-through, string
      # keys — the FirstRunContract type validates at write time, one
      # enforcement point like the env-var schema below.
      first_run: Map.get(version, "first_run"),
      # OIDC wiring recipe (#597): raw pass-through, string keys — the
      # OidcWiring type + ValidateOidcWiringEnv validate at write time
      # (one enforcement point, the first_run stance).
      oidc_wiring: Map.get(version, "oidc_wiring"),
      # Bundled backing services (#612, ADR-0045): raw pass-through,
      # string keys — the BackingService type + ValidateBackingServices
      # validate at write time (one enforcement point). Defaults to []
      # so entries without the key converge to "no services" (the
      # first_run/oidc_wiring opt-in stance); no shipped entry declares
      # any yet.
      backing_services: Map.get(version, "backing_services", []),
      default_cpu_cores: cpu_cores(version),
      default_memory_mb: Map.get(version, "default_memory_mb", 256),
      default_storage_gb: Map.get(version, "default_storage_gb", 0),
      recommended_size: recommended_size!(version),
      release_notes: version["release_notes"],
      published_at: published_at(version)
    }
  end

  # Required, not defaulted: an unpriced version is a silent billing hole
  # (ADR-0028). Failing at parse time names the offending version.
  defp recommended_size!(version) do
    case Map.fetch(version, "recommended_size") do
      {:ok, slug} ->
        slug

      :error ->
        raise "catalog seed: version #{inspect(version["version"])} must name a recommended_size"
    end
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
