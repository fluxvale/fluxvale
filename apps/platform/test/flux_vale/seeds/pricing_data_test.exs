defmodule FluxVale.Seeds.PricingDataTest do
  @moduledoc """
  Unit tests for pricing YAML normalization — no database. These also
  carry the calibration check (ADR-0028's launch-gate, #125): the
  shipped cents must equal the anchor curve's axes — the compute rate
  per size (#558: CPU + memory terms, storage excluded) and the per-GB
  storage rate — which is the SAME code the ledger prices custom
  allocations with (#186, `FluxVale.Pricing.price_allocation/1`) — the
  constants live once, in lib; a hand-edit that drifts the table from
  the curve fails loudly here.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Pricing
  alias FluxVale.Pricing.Operations.PriceAllocation
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
      assert small.monthly_cents == 295
    end

    test "a size entry carries compute only — no storage, no stopped rate (#558)" do
      for size <- PricingData.entries() do
        refute Map.has_key?(size, :storage_gb),
               "size #{size.slug}: storage must not ride a compute class"

        refute Map.has_key?(size, :stopped_monthly_cents),
               "size #{size.slug}: a stopped rate must not ride a compute class"
      end
    end
  end

  # Ground truth, the B′ compute rates from
  # docs/pricing-recalibration-2026-10.md's Option B′ table as amended
  # for #558 (the owner's #200 decision, per-axis rounded): literals,
  # not derived — if the YAML or the curve drifts from the DECIDED
  # table, this fails even if the two stay mutually consistent. The
  # ladder is these six sizes: #233's proposed top rungs were rejected
  # on #399, so there is no extension table to pin.
  @doc_b_prime_compute %{
    micro: 259,
    small: 295,
    medium: 369,
    standard: 553,
    plus: 861,
    pro: 1379
  }

  # The storage axis at the sizes' historical bundled storages (the old
  # table's stopped column — unchanged per-GB pricing, its own
  # dimension now).
  @storage_axis %{
    "micro" => 5,
    "small" => 10,
    "medium" => 10,
    "standard" => 20,
    "plus" => 50,
    "pro" => 100
  }

  describe "the decided B′ table" do
    test "every shipped size carries the doc's B′ compute rate" do
      for size <- PricingData.entries() do
        # to_existing_atom: the pinned keys above already exist — a
        # YAML slug matching no pinned row must raise, not mint an atom.
        slug_atom = String.to_existing_atom(size.slug)
        monthly = Map.fetch!(@doc_b_prime_compute, slug_atom)

        assert size.monthly_cents == monthly,
               "size #{size.slug}: #{size.monthly_cents}¢ ≠ the pinned B′ compute rate (#{monthly}¢)"
      end
    end

    test "no SG rows ship — the standby variant is structure, not seeds" do
      slugs = Enum.map(PricingData.entries(), & &1.slug)

      refute Enum.any?(slugs, &String.contains?(&1, ["sg", "singapore"])),
             "B′-SG prices must not seed until the SG box exists (#206 scope)"
    end
  end

  describe "calibration vs the market anchor" do
    test "every shipped compute rate equals the v5 curve's compute axis (half-up cents)" do
      for size <- PricingData.entries() do
        expected =
          PriceAllocation.compute_cents(
            %{cpu_cores: size.cpu_cores, memory_mb: size.memory_mb},
            :nuremberg
          )

        assert size.monthly_cents == expected,
               "size #{size.slug}: #{size.monthly_cents}¢ drifts from the compute axis (#{expected}¢)"
      end
    end

    test "the per-GB storage axis prices the historical bundled storages at the old stopped cents" do
      # The bundled era's stopped column is the axis at each size's
      # historical storage — the unchanged per-GB pricing, restated.
      old_stopped = %{
        "micro" => 24,
        "small" => 40,
        "medium" => 40,
        "standard" => 68,
        "plus" => 135,
        "pro" => 228
      }

      for {slug, gb} <- @storage_axis do
        expected = Pricing.storage_monthly_cents(gb)

        assert expected == Map.fetch!(old_stopped, slug),
               "#{slug}'s historical #{gb} GB: the storage axis drifted from the bundled stopped cents"
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
        monthly_cents: 259
      """

      path = tmp_path(yaml)

      assert PricingData.entries(path) == [
               %{
                 slug: "tiny",
                 cpu_cores: Decimal.new("0.25"),
                 memory_mb: 512,
                 monthly_cents: 259
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
