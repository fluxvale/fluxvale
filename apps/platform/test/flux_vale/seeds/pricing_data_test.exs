defmodule FluxVale.Seeds.PricingDataTest do
  @moduledoc """
  Unit tests for pricing YAML normalization — no database. These also
  carry the calibration check (ADR-0028's launch-gate, #125): the shipped
  cents must equal the market-anchor curve at each size's allocation, so
  a hand-edit that drifts the table from the documented anchor fails
  loudly here.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Seeds.PricingData

  # The market anchor curve (pricing version 4, recorded 2026-10-12,
  # verified against the source's public calculator: its 0.25 core /
  # 0.25 GB / 0 GB default computes to the $1.80 it displays). Named
  # source out of the repo per ADR-0018 Am. 1; full write-up:
  # docs/pricing-calibration.md.
  @anchor_v4 %{
    cpu_multiplier: 1.35,
    cpu_exponent: 0.6,
    cpu_base: 0.7340567521199421,
    memory_multiplier: 1.45,
    memory_exponent: 0.8,
    storage_multiplier: 0.06,
    storage_exponent: 0.75
  }

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
        expected = anchor_cents(size.cpu_cores, size.memory_mb, size.storage_gb)

        assert size.monthly_cents == expected,
               "size #{size.slug}: #{size.monthly_cents}¢ drifts from the anchor (#{expected}¢)"
      end
    end

    test "every shipped stopped price equals the v4 storage term (half-up cents)" do
      for size <- PricingData.entries() do
        expected = anchor_storage_cents(size.storage_gb)

        assert size.stopped_monthly_cents == expected,
               "size #{size.slug}: stopped #{size.stopped_monthly_cents}¢ drifts from the v4 storage term (#{expected}¢)"
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

  defp anchor_cents(cpu_cores, memory_mb, storage_gb) do
    # Memory rides the curve in GB (the anchor's unit): 512 MB = 0.5.
    cpu = Decimal.to_float(cpu_cores)

    usd =
      @anchor_v4.cpu_multiplier * :math.pow(cpu, @anchor_v4.cpu_exponent) +
        @anchor_v4.cpu_base +
        @anchor_v4.memory_multiplier * :math.pow(memory_mb / 1024, @anchor_v4.memory_exponent) +
        @anchor_v4.storage_multiplier * :math.pow(storage_gb / 1, @anchor_v4.storage_exponent)

    trunc(usd * 100 + 0.5)
  end

  defp anchor_storage_cents(storage_gb) do
    usd = @anchor_v4.storage_multiplier * :math.pow(storage_gb / 1, @anchor_v4.storage_exponent)
    trunc(usd * 100 + 0.5)
  end

  defp tmp_path(contents) do
    path = Path.join(System.tmp_dir!(), "pricing_data_#{System.unique_integer()}.yaml")
    File.write!(path, contents)
    path
  end
end
