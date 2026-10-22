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
  alias FluxVale.Seeds.PricingData

  describe "calibration: the seeded table is the curve at size points" do
    test "every shipped size prices to exactly its seeded cents, running and stopped" do
      for size <- PricingData.entries() do
        allocation = %{
          cpu_cores: size.cpu_cores,
          memory_mb: size.memory_mb,
          storage_gb: size.storage_gb
        }

        rates = Pricing.price_allocation(allocation)

        assert rates == %{
                 monthly_cents: size.monthly_cents,
                 stopped_monthly_cents: size.stopped_monthly_cents
               },
               "size #{size.slug}: the curve drifted from the seed table"
      end
    end

    test "the doc's verified calculator point holds (0.25 core / 0.25 GB / 0 GB = $1.80 ×1.2)" do
      # pricing-calibration.md's own anchor verification: the source's
      # public calculator shows $1.80 for its 0.25/0.25/0 default — v4.
      # v5 surcharges the curve (B′ ×1.2): 180¢ → 216¢, the value
      # docs/pricing-recalibration-2026-10.md pins for B′.
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
    # pins the standby variant to the recalibration doc's B′-SG table,
    # ready for the day SG prices seed. No SG rows ship in the YAML.
    test ":singapore (standby, unseeded) prices the doc's B′-SG table exactly" do
      # Ground truth: docs/pricing-recalibration-2026-10.md, "The
      # Singapore extension" — B′-SG ×1.25 column.
      b_prime_sg = %{
        micro: {294, 25},
        small: {349, 42},
        medium: {427, 42},
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

  # The seeded allocation behind a slug (PricingData carries the six
  # sizes) — table-driven tests iterate the doc's per-size tables.
  defp allocation_for(slug) do
    size = Enum.find(PricingData.entries(), &(&1.slug == Atom.to_string(slug)))

    %{
      cpu_cores: size.cpu_cores,
      memory_mb: size.memory_mb,
      storage_gb: size.storage_gb
    }
  end

  defp cpu_hundredths do
    (5 + :rand.uniform(795))
    |> Integer.to_string()
    |> Decimal.new()
  end
end
