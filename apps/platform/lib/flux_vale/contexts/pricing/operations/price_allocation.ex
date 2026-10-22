defmodule FluxVale.Pricing.Operations.PriceAllocation do
  @moduledoc """
  ADR-0028's price = f(allocation) as code (#186): the market-anchor
  curve v4 (recorded 2026-10-12, verified against the source's public
  calculator; the named source stays out of the repo per ADR-0018
  Am. 1 — full write-up in docs/pricing-calibration.md), evaluated at
  any allocation for custom-sized instances:

      $/mo = 1.35·cores^0.6 + 0.734   (CPU, incl. per-instance base)
           + 1.45·ram_gb^0.8          (memory)
           + 0.06·storage_gb^0.75     (storage)

  Curve v5 (#206, decided on #200 from
  docs/pricing-recalibration-2026-10.md): the v4 curve times a
  per-region surcharge m — pricing is per-datencenter, so a region's
  floor rides its own multiplier, not a second curve. `:nuremberg`
  (the one seeded region) is B′ ×1.2; `:singapore` is the decided
  B′-SG ×1.25 on standby — present so the variant is structure, not
  a rewrite, but seeded nowhere (no SG rows ship until the SG box
  exists; activating it is a seed diff plus region wiring, no
  migration).

  Stopped = the storage term alone (ADR-0028 §2), surcharge included.
  Whole US cents, halves rounded up — the same rounding the seeded
  table was built with, so the formula reproduces every seeded size's
  cents exactly (pinned by the calibration tests). One module owns
  the curve: the seed-calibration tests assert the shipped YAML
  against THIS module, never a second copy of the constants.

  Terence's #180 decision (option a, continuous formula): the wizard's
  live estimate and the ledger's charge both price through here, so a
  custom allocation's shown price is its charged price by
  construction. Seeded-size instances keep snapshotting their Size row
  (#121's model — admin price edits stay effective for them); at the
  seeded allocations the two paths agree exactly.
  """

  # The curve, as extracted for the calibration check (v4). cpu_base
  # carries full double precision — the doc rounds it to 0.734.
  @cpu_multiplier 1.35
  @cpu_exponent 0.6
  @cpu_base 0.7340567521199421
  @memory_multiplier 1.45
  @memory_exponent 0.8
  @storage_multiplier 0.06
  @storage_exponent 0.75

  # v5's regional surcharges (#206): the v4 curve ×m, per datencenter.
  # A new region slots in as one map entry — everything downstream
  # (rounding, seeds, snapshots) is region-agnostic by construction.
  @regional_multipliers %{
    nuremberg: 1.2,
    singapore: 1.25
  }

  @gb_mb 1024

  @doc """
  Prices an allocation: the flat monthly cents while running and the
  storage-only cents while stopped. `cpu_cores` is a Decimal; memory
  and storage are integers in MB / GB. The allocation is assumed
  floor-legal (the Instance attribute constraints) — every floor-legal
  value is mathematically fine here (0 storage prices to 0¢ stopped).

  `region` selects the v5 surcharge — required here; the domain's
  `price_allocation/2` owns the default (`:nuremberg`, the one seeded
  region), so the default lives at exactly one seam. An unknown
  region raises rather than pricing at a guess: a typo'd region on a
  charge path must fail loudly.
  """
  @spec call(
          %{cpu_cores: Decimal.t(), memory_mb: pos_integer(), storage_gb: non_neg_integer()},
          atom()
        ) ::
          %{
            monthly_cents: non_neg_integer(),
            stopped_monthly_cents: non_neg_integer()
          }
  def call(allocation, region) do
    surcharge = regional_surcharge(region)
    cpu_cores = Decimal.to_float(allocation.cpu_cores)
    memory_gb = allocation.memory_mb / @gb_mb
    storage_gb = allocation.storage_gb / 1

    storage_usd = storage_term(storage_gb)

    usd =
      @cpu_multiplier * :math.pow(cpu_cores, @cpu_exponent) + @cpu_base +
        @memory_multiplier * :math.pow(memory_gb, @memory_exponent) +
        storage_usd

    %{
      monthly_cents: half_up_cents(surcharge * usd),
      stopped_monthly_cents: half_up_cents(surcharge * storage_usd)
    }
  end

  defp regional_surcharge(region) do
    case Map.fetch(@regional_multipliers, region) do
      {:ok, surcharge} -> surcharge
      :error -> raise ArgumentError, "unknown pricing region #{inspect(region)}"
    end
  end

  defp storage_term(storage_gb) do
    @storage_multiplier * :math.pow(storage_gb, @storage_exponent)
  end

  # Whole cents, exact halves up — the seed table's documented rounding
  # (docs/pricing-calibration.md); trunc-after-add implements half-up
  # for the non-negative values this curve produces.
  defp half_up_cents(usd) do
    trunc(usd * 100 + 0.5)
  end
end
