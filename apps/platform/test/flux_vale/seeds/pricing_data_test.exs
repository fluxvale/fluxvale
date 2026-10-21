defmodule FluxVale.Seeds.PricingDataTest do
  @moduledoc """
  Unit tests for pricing YAML normalization — no database. These also
  carry the calibration check (ADR-0028's launch-gate, #125): the
  shipped cents must equal the anchor curve at each size's allocation,
  which is now the SAME code the ledger prices custom allocations with
  (#186, `FluxVale.Pricing.price_allocation/1`) — the constants live
  once, in lib; a hand-edit that drifts the table from the curve fails
  loudly here.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Pricing
  alias FluxVale.Seeds.PricingData

  describe "entries/0 (shipped data)" do
    test "carries the six sizes, keyed by slug" do
      sizes = PricingData.entries()
      slugs = Enum.map(sizes, & &1.slug)

      assert slugs == ~w(micro small medium standard plus pro)
    end

    test "normalizes quoted cpu strings to Decimal and keeps integer cents" do
      small = size_by_slug!("small")

      assert Decimal.equal?(small.cpu_cores, Decimal.new("0.5"))
      assert small.memory_mb == 512
      assert small.storage_gb == 10
      assert small.monthly_cents == 279
      assert small.stopped_monthly_cents == 34
    end
  end

  describe "calibration vs the market anchor" do
    test "every shipped running price equals the v4 curve (half-up cents)" do
      for size <- PricingData.entries() do
        expected = Pricing.price_allocation(size).monthly_cents

        assert size.monthly_cents == expected,
               "size #{size.slug}: #{size.monthly_cents}¢ drifts from the anchor (#{expected}¢)"
      end
    end

    test "every shipped stopped price equals the v4 storage term (half-up cents)" do
      for size <- PricingData.entries() do
        expected = Pricing.price_allocation(size).stopped_monthly_cents

        assert size.stopped_monthly_cents == expected,
               "size #{size.slug}: stopped #{size.stopped_monthly_cents}¢ drifts from the anchor's storage term (#{expected}¢)"
      end
    end
  end

  describe "entries/1" do
    test "comments-only and empty files parse to []" do
      comments_only = tmp_path("# comments only\n")
      assert PricingData.entries(comments_only) == []

      empty = tmp_path("")
      assert PricingData.entries(empty) == []
    end

    test "normalizes an entry to an atom-keyed map" do
      yaml = """
      - slug: tiny
        cpu_cores: "0.25"
        memory_mb: 512
        storage_gb: 5
        monthly_cents: 236
        stopped_monthly_cents: 20
      """

      path = tmp_path(yaml)

      assert PricingData.entries(path) == [
               %{
                 slug: "tiny",
                 cpu_cores: Decimal.new("0.25"),
                 memory_mb: 512,
                 storage_gb: 5,
                 monthly_cents: 236,
                 stopped_monthly_cents: 20
               }
             ]
    end
  end

  defp size_by_slug!(slug) do
    sizes = PricingData.entries()
    Enum.find(sizes, &(&1.slug == slug))
  end

  defp tmp_path(contents) do
    path = Path.join(System.tmp_dir!(), "pricing_data_#{System.unique_integer()}.yaml")
    File.write!(path, contents)
    path
  end
end
