defmodule FluxVale.Seeds.TaxRateDataTest do
  @moduledoc """
  Unit tests for the VAT rate YAML normalization — no database. These
  also pin the launch table's shape (#138): EU-27 + UK, dated rows, the
  rates the settled design names (DE 19%, FR 20%, IE 23%, UK 20%).
  """

  use ExUnit.Case, async: true

  alias FluxVale.Seeds.TaxRateData

  @eu_27 ~w(AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK)

  describe "entries/0 (shipped data)" do
    test "carries EU-27 + UK, every jurisdiction dated" do
      entries = TaxRateData.entries()
      countries = Enum.map(entries, & &1.country)

      assert countries
             |> Enum.uniq()
             |> Enum.sort() == Enum.sort(@eu_27 ++ ["GB"])

      for entry <- entries do
        assert Regex.match?(~r/^[A-Z]{2}$/, entry.country)
        assert is_integer(entry.rate_bp) and entry.rate_bp in 0..10_000
        assert %DateTime{} = entry.effective_from
        # The launch table is country-wide rows only (US states arrive
        # with US nexus registration).
        assert entry.state == nil
      end
    end

    test "carries the rates the settled design names" do
      by_key = key_entries(TaxRateData.entries())

      assert by_key[{"DE", "2021-01-01"}].rate_bp == 1900
      assert by_key[{"FR", "2021-01-01"}].rate_bp == 2000
      assert by_key[{"IE", "2021-01-01"}].rate_bp == 2300
      assert by_key[{"GB", "2021-01-01"}].rate_bp == 2000
    end

    test "effective dating supersedes in-table (movers carry their change date)" do
      by_key = key_entries(TaxRateData.entries())

      assert by_key[{"FI", "2021-01-01"}].rate_bp == 2400
      assert by_key[{"FI", "2024-09-01"}].rate_bp == 2550
      assert by_key[{"SK", "2025-01-01"}].rate_bp == 2300

      # EE's step-ups are July-dated (EMTA: 22% from 2024-07-01, 24% from
      # 2025-07-01 — the corrected dating, #260).
      assert by_key[{"EE", "2024-07-01"}].rate_bp == 2200
      assert by_key[{"EE", "2025-07-01"}].rate_bp == 2400
      refute Map.has_key?(by_key, {"EE", "2024-01-01"})
    end

    test "no two rows share a lookup key" do
      keys =
        Enum.map(TaxRateData.entries(), fn entry ->
          {entry.country, entry.state, DateTime.to_iso8601(entry.effective_from)}
        end)

      assert length(keys) == length(Enum.uniq(keys))
    end
  end

  describe "entries/1" do
    test "comments-only and empty files parse to []" do
      comments_only = tmp_path("# comments only\n")
      assert TaxRateData.entries(comments_only) == []

      empty = tmp_path("")
      assert TaxRateData.entries(empty) == []
    end

    test "normalizes entries to atom-keyed maps with a parsed DateTime" do
      yaml = """
      - country: DE
        rate_bp: 1900
        effective_from: "2021-01-01T00:00:00Z"
      - country: US
        state: CA
        rate_bp: 800
        effective_from: "2026-01-01T00:00:00Z"
      """

      path = tmp_path(yaml)

      assert TaxRateData.entries(path) == [
               %{
                 country: "DE",
                 state: nil,
                 rate_bp: 1900,
                 effective_from: ~U[2021-01-01 00:00:00Z]
               },
               %{
                 country: "US",
                 state: "CA",
                 rate_bp: 800,
                 effective_from: ~U[2026-01-01 00:00:00Z]
               }
             ]
    end
  end

  defp key_entries(entries) do
    Map.new(entries, fn entry ->
      date =
        entry.effective_from
        |> DateTime.to_date()
        |> Date.to_iso8601()

      {{entry.country, date}, entry}
    end)
  end

  defp tmp_path(contents) do
    path = Path.join(System.tmp_dir!(), "tax_rates_#{System.unique_integer()}.yaml")
    File.write!(path, contents)
    path
  end
end
