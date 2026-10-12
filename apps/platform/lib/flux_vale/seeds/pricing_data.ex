defmodule FluxVale.Seeds.PricingData do
  @moduledoc """
  Declarative pricing seed data, loaded from
  `priv/repo/seeds/pricing_data.yaml` (#125).

  The shipped file carries the six allocation sizes anchored to the
  market reference curve (ADR-0028; named sources stay out of the repo,
  ADR-0018 Am. 1) — the calibration against the box COGS
  (docs/pricing-calibration.md) keeps the anchor honest, and
  `pricing_data_test.exs` re-checks the shipped cents against that
  anchor on every run.

  Adding or repricing a size is purely additive/administrative: append or
  edit a YAML entry and re-run seeds — the seed runner
  (`FluxVale.Seeds.seed_pricing!/0`) looks each record up by slug and
  updates it to match the YAML, so re-running converges with zero dupes.
  Cents edits are always safe. **Allocation edits are not**: referenced
  sizes are allocation-frozen (`ValidateAllocationFrozen`), so moving a
  size's cpu/memory/storage means editing `catalog_data.yaml`'s version
  defaults in the same seed run — a lone YAML allocation edit crashes
  bring-up on the freeze.

  Type normalization (YAML is lossy vs Elixir literals): `cpu_cores` is a
  quoted string (`"0.5"`) to avoid float precision loss; converted to
  `Decimal` here. Every field is required — a size row is fully
  specified, there are no defaults to hide a typo behind.
  """

  @spec entries :: [map()]
  def entries, do: entries(default_path())

  @doc """
  Parses size entries from a specific YAML file — the 1-arity exists so
  normalization is testable against fixture YAML without touching the
  real seed data.
  """
  @spec entries(Path.t()) :: [map()]
  def entries(path) do
    contents = File.read!(path)
    parsed = YamlElixir.read_from_string!(contents)

    case parsed do
      entries when is_list(entries) ->
        Enum.map(entries, &normalize_size/1)

      # Empty/comments-only file parses to nil or %{} — a deliberately
      # empty price table is valid (the machinery tolerates it).
      _empty ->
        []
    end
  end

  defp default_path do
    :flux_vale
    |> :code.priv_dir()
    |> Path.join("repo/seeds/pricing_data.yaml")
  end

  defp normalize_size(size) do
    %{
      slug: size["slug"],
      cpu_cores: Decimal.new(size["cpu_cores"]),
      memory_mb: size["memory_mb"],
      storage_gb: size["storage_gb"],
      monthly_cents: size["monthly_cents"],
      stopped_monthly_cents: size["stopped_monthly_cents"]
    }
  end
end
