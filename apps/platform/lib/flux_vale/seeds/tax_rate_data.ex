defmodule FluxVale.Seeds.TaxRateData do
  @moduledoc """
  Declarative VAT rate seed data, loaded from
  `priv/repo/seeds/tax_rates.yaml` (#138, ADR-0029 Am. 3 gate 2).

  The shipped file carries the launch table — EU-27 standard rates +
  UK, each dated `effective_from` (nil-state, country-wide rows; US
  state rows arrive with US nexus registration). **Launch data, not an
  audited feed**: the shipped rates must be re-verified against the
  official source before production (the registrations gate); sources
  stay unnamed in the repo (ADR-0018 Am. 1).

  Adding or repricing a rate is purely additive/administrative: append
  or edit a YAML entry and re-run seeds — the seed runner
  (`FluxVale.Seeds.seed_tax_rates!/0`) looks each record up by
  (country, state, effective_from) and updates its rate_bp to match the
  YAML, so re-running converges with zero dupes. A new effective date
  is a NEW row — the old row stays (it just stops resolving); there is
  no `effective_to`.

  Type normalization (YAML is lossy vs Elixir literals): `effective_from`
  is an ISO 8601 string; parsed to `DateTime` here. Country, rate_bp are
  required; state is optional (nil = country-wide).
  """

  @spec entries :: [map()]
  def entries, do: entries(default_path())

  @doc """
  Parses tax-rate entries from a specific YAML file — the 1-arity exists
  so normalization is testable against fixture YAML without touching the
  real seed data.
  """
  @spec entries(Path.t()) :: [map()]
  def entries(path) do
    contents = File.read!(path)
    parsed = YamlElixir.read_from_string!(contents)

    case parsed do
      entries when is_list(entries) ->
        Enum.map(entries, &normalize_entry/1)

      # Empty/comments-only file parses to nil or %{} — a deliberately
      # empty rate table is valid (the machinery tolerates it).
      _empty ->
        []
    end
  end

  defp default_path do
    :flux_vale
    |> :code.priv_dir()
    |> Path.join("repo/seeds/tax_rates.yaml")
  end

  defp normalize_entry(entry) do
    %{
      country: entry["country"],
      state: entry["state"],
      rate_bp: entry["rate_bp"],
      effective_from: parse_datetime!(entry["effective_from"])
    }
  end

  defp parse_datetime!(iso8601_string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601_string)
    datetime
  end
end
