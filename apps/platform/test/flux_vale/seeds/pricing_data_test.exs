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
    test "carries the eight sizes, keyed by slug" do
      sizes = PricingData.entries()
      slugs = Enum.map(sizes, & &1.slug)

      assert slugs == ~w(micro small medium standard plus pro ultra max)
    end

    test "normalizes quoted cpu strings to Decimal and keeps integer cents" do
      small = size_by_slug!("small")

      assert Decimal.equal?(small.cpu_cores, Decimal.new("0.5"))
      assert small.memory_mb == 512
      assert small.storage_gb == 10
      assert small.monthly_cents == 335
      assert small.stopped_monthly_cents == 40
    end
  end

  # Ground truth, copied from docs/pricing-recalibration-2026-10.md's
  # Option B′ table (the owner's #200 decision) — literals, not derived:
  # if the YAML or the curve drifts from the DECIDED table, this fails
  # even if the two stay mutually consistent.
  @doc_b_prime %{
    micro: {283, 24},
    small: {335, 40},
    medium: {409, 40},
    standard: {621, 68},
    plus: {996, 135},
    pro: {1606, 228}
  }

  # The #233 top-rung extension: no doc-decided table exists for these
  # two — the cents are the same v5 curve at the new allocations,
  # pinned as literals because they are pricing-bearing (this is the
  # rung table the owner signs off on #233), so a YAML or curve drift
  # must fail here exactly like a doc-row drift does.
  @ladder_extension %{
    ultra: {2216, 383},
    max: {2895, 644}
  }

  describe "the decided B′ table + the #233 top-rung extension" do
    test "every shipped size carries the doc's B′ cents (or the #233 extension's), running and stopped" do
      pinned = Map.merge(@doc_b_prime, @ladder_extension)

      for size <- PricingData.entries() do
        # to_existing_atom: the pinned keys above already exist — a
        # YAML slug matching no pinned row must raise, not mint an atom.
        slug_atom = String.to_existing_atom(size.slug)
        {monthly, stopped} = Map.fetch!(pinned, slug_atom)

        assert {size.monthly_cents, size.stopped_monthly_cents} == {monthly, stopped},
               "size #{size.slug}: {#{size.monthly_cents}, #{size.stopped_monthly_cents}} ≠ the pinned B′ {#{monthly}, #{stopped}}"
      end
    end

    test "no SG rows ship — the standby variant is structure, not seeds" do
      slugs = Enum.map(PricingData.entries(), & &1.slug)

      refute Enum.any?(slugs, &String.contains?(&1, ["sg", "singapore"])),
             "B′-SG prices must not seed until the SG box exists (#206 scope)"
    end
  end

  describe "calibration vs the market anchor" do
    test "every shipped running price equals the v5 curve (half-up cents)" do
      for size <- PricingData.entries() do
        expected = Pricing.price_allocation(size).monthly_cents

        assert size.monthly_cents == expected,
               "size #{size.slug}: #{size.monthly_cents}¢ drifts from the anchor (#{expected}¢)"
      end
    end

    test "every shipped stopped price equals the v5 storage term (half-up cents)" do
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
        monthly_cents: 283
        stopped_monthly_cents: 24
      """

      path = tmp_path(yaml)

      assert PricingData.entries(path) == [
               %{
                 slug: "tiny",
                 cpu_cores: Decimal.new("0.25"),
                 memory_mb: 512,
                 storage_gb: 5,
                 monthly_cents: 283,
                 stopped_monthly_cents: 24
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
