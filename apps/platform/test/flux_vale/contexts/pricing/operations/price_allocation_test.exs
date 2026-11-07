defmodule FluxVale.Pricing.Operations.PriceAllocationTest do
  @moduledoc """
  The anchor curve as code (#186): exact reproduction of the shipped
  seed table (the calibration contract — docs/pricing-calibration.md)
  and the structural properties any continuous price = f(allocation)
  must hold, over deterministic random allocations (no new dep: a
  seeded :rand stream; same numbers on every run).
  """

  use ExUnit.Case, async: true

  alias FluxVale.Pricing
  alias FluxVale.Pricing.Operations.PriceAllocation
  alias FluxVale.Seeds.PricingData

  describe "calibration: the seeded table is the curve at size points" do
    test "every shipped size's monthly rate is the curve's compute axis exactly" do
      # #558: a size row prices the compute class — CPU + memory terms,
      # storage excluded. The storage axis (below) prices separately.
      for size <- PricingData.entries() do
        compute =
          PriceAllocation.compute_cents(
            %{cpu_cores: size.cpu_cores, memory_mb: size.memory_mb},
            :nuremberg
          )

        assert compute == size.monthly_cents,
               "size #{size.slug}: the compute axis drifted from the seed table"
      end
    end

    test "the storage axis prices the reference ladder exactly (#558)" do
      # The old bundled table's stopped column IS the per-GB axis at the
      # historical bundled storages — unchanged cents, now stated as its
      # own dimension (docs/pricing-calibration.md's amended table).
      assert PriceAllocation.storage_cents(5, :nuremberg) == 24
      assert PriceAllocation.storage_cents(10, :nuremberg) == 40
      assert PriceAllocation.storage_cents(20, :nuremberg) == 68
      assert PriceAllocation.storage_cents(50, :nuremberg) == 135
      assert PriceAllocation.storage_cents(100, :nuremberg) == 228
    end

    test "a whole allocation prices as the two axes summed, never a third way" do
      for allocation <- allocations(100) do
        compute =
          PriceAllocation.compute_cents(
            %{cpu_cores: allocation.cpu_cores, memory_mb: allocation.memory_mb},
            :nuremberg
          )

        storage = PriceAllocation.storage_cents(allocation.storage_gb, :nuremberg)
        rates = Pricing.price_allocation(allocation)

        assert rates.monthly_cents == compute + storage
        assert rates.stopped_monthly_cents == storage
      end
    end

    test "the doc's verified calculator point holds (0.25 core / 0.25 GB / 0 GB = $1.80 ×1.2)" do
      # pricing-calibration.md's own anchor verification: the source's
      # public calculator shows $1.80 for its 0.25/0.25/0 default — v4.
      # v5 surcharges the curve (B′ ×1.2): 180¢ → 216¢, the value
      # docs/pricing-recalibration-2026-10.md pins for B′. Zero storage
      # makes the point per-axis exact by construction.
      rates =
        Pricing.price_allocation(%{
          cpu_cores: Decimal.new("0.25"),
          memory_mb: 256,
          storage_gb: 0
        })

      assert rates == %{monthly_cents: 216, stopped_monthly_cents: 0}
    end
  end

  describe "regional variants (curve v5, #206)" do
    test ":nuremberg is the default — both arities price identically" do
      allocation = %{cpu_cores: Decimal.new("0.5"), memory_mb: 512, storage_gb: 10}

      assert Pricing.price_allocation(allocation) ==
               Pricing.price_allocation(allocation, :nuremberg)
    end

    # The SG extension proof: a ×1.25 variant slots in as ONE map
    # entry in PriceAllocation (no migration, no curve rewrite) — this
    # pins the standby variant to the recalibration doc's B′-SG table
    # as amended for #558's per-axis rounding, ready for the day SG
    # prices seed. No SG rows ship in the YAML.
    test ":singapore (standby, unseeded) prices the doc's B′-SG table exactly" do
      # Ground truth: docs/pricing-recalibration-2026-10.md, "The
      # Singapore extension" — B′-SG ×1.25 column, per-axis rounded
      # (#558): medium's total reads 426¢ here where the round-the-sum
      # figure was 427¢.
      b_prime_sg = %{
        micro: {294, 25},
        small: {349, 42},
        medium: {426, 42},
        standard: {647, 71},
        plus: {1038, 141},
        pro: {1673, 237}
      }

      for {slug, {monthly, stopped}} <- b_prime_sg do
        allocation = allocation_for(slug)

        rates = Pricing.price_allocation(allocation, :singapore)

        assert rates == %{monthly_cents: monthly, stopped_monthly_cents: stopped},
               "B′-SG #{slug}: #{inspect(rates)} drifts from the doc's table"
      end
    end

    test "an unknown region raises rather than pricing a guess" do
      allocation = %{cpu_cores: Decimal.new("0.5"), memory_mb: 512, storage_gb: 10}

      assert_raise ArgumentError, "unknown pricing region :mars", fn ->
        Pricing.price_allocation(allocation, :mars)
      end
    end
  end

  describe "properties over random allocations" do
    test "running ≥ stopped always (the storage term is a summand, never the whole)" do
      for allocation <- allocations(500) do
        rates = Pricing.price_allocation(allocation)

        assert rates.monthly_cents >= rates.stopped_monthly_cents,
               "running #{rates.monthly_cents}¢ < stopped #{rates.stopped_monthly_cents}¢ at #{inspect(allocation)}"
      end
    end

    test "prices never decrease when any dimension grows (monotone per dimension)" do
      for allocation <- allocations(200) do
        base = Pricing.price_allocation(allocation)

        bigger_cpu =
          Pricing.price_allocation(%{
            allocation
            | cpu_cores: Decimal.add(allocation.cpu_cores, Decimal.new("0.05"))
          })

        bigger_memory =
          Pricing.price_allocation(%{allocation | memory_mb: allocation.memory_mb + 128})

        bigger_storage =
          Pricing.price_allocation(%{allocation | storage_gb: allocation.storage_gb + 1})

        assert bigger_cpu.monthly_cents >= base.monthly_cents
        assert bigger_memory.monthly_cents >= base.monthly_cents
        assert bigger_storage.monthly_cents >= base.monthly_cents
        assert bigger_storage.stopped_monthly_cents >= base.stopped_monthly_cents
      end
    end

    test "every price is non-negative whole cents" do
      for allocation <- allocations(500) do
        rates = Pricing.price_allocation(allocation)

        assert is_integer(rates.monthly_cents) and rates.monthly_cents >= 0
        assert is_integer(rates.stopped_monthly_cents) and rates.stopped_monthly_cents >= 0
      end
    end

    test "stopped is the storage term alone: zero storage is free stopped" do
      rates =
        Pricing.price_allocation(%{
          cpu_cores: Decimal.new("2"),
          memory_mb: 4096,
          storage_gb: 0
        })

      assert rates.stopped_monthly_cents == 0
      assert rates.monthly_cents > 0
    end
  end

  describe "floor-legal extremes price without error" do
    test "the smallest sensible allocation prices positive-running, zero-stopped" do
      rates =
        Pricing.price_allocation(%{
          cpu_cores: Decimal.new("0.05"),
          memory_mb: 1,
          storage_gb: 0
        })

      assert rates.monthly_cents > 0
      assert rates.stopped_monthly_cents == 0
    end

    test "the wizard ceiling allocation (64 cores / 64 GB / 10 TB) prices" do
      rates =
        Pricing.price_allocation(%{
          cpu_cores: Decimal.new("64"),
          memory_mb: 65_536,
          storage_gb: 10_240
        })

      assert rates.monthly_cents > rates.stopped_monthly_cents
      assert rates.stopped_monthly_cents > 0
    end
  end

  # Deterministic random allocations across the wizard's practical
  # range (seeded — the same corpus every run, no flake surface): cpu
  # 0.05–8.00 in hundredths (Decimal.new/exact — no float rounding on
  # the corpus values themselves), memory 192–8192 MB, storage 1–512 GB.
  defp allocations(count) do
    :rand.seed(:exsss, {186, 1_020, 2_026})

    Enum.map(1..count//1, fn _i ->
      cpu = Decimal.div(cpu_hundredths(), 100)

      %{
        cpu_cores: cpu,
        memory_mb: 64 + 128 * :rand.uniform(62),
        storage_gb: :rand.uniform(512)
      }
    end)
  end

  # The reference allocation behind a slug (#558): the size row carries
  # the compute shape; the storage GB is the size's historical bundled
  # value, kept here as the doc tables' reference point.
  @reference_storage %{
    "micro" => 5,
    "small" => 10,
    "medium" => 10,
    "standard" => 20,
    "plus" => 50,
    "pro" => 100
  }

  defp allocation_for(slug) do
    slug_string = Atom.to_string(slug)
    size = Enum.find(PricingData.entries(), &(&1.slug == slug_string))

    %{
      cpu_cores: size.cpu_cores,
      memory_mb: size.memory_mb,
      storage_gb: Map.fetch!(@reference_storage, slug_string)
    }
  end

  defp cpu_hundredths do
    (5 + :rand.uniform(795))
    |> Integer.to_string()
    |> Decimal.new()
  end
end
