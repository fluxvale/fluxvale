defmodule FluxVale.Infrastructure.Instance.PricingSnapshot do
  @moduledoc """
  The one pricing-snapshot choice (#121/#186, shared per #493): given
  an allocation, the AppVersion it came from, and now — what the
  instance row's pricing triple is.

  - At the version's recommendation (all three dimensions on its
    defaults) the recommended `Size` row snapshots: `size_id` plus its
    two cents fields. A sizeless recommendation → unpriced (all nil —
    billing never guesses; the pre-#125 drift shape).
  - Any dimension off → the anchor formula's cents
    (`Pricing.price_allocation/1`), no size.

  Always a fresh `now + 1 year` grandfather clock — except the unpriced
  arm, which carries a nil clock (mirroring create's no-op path).

  **The #493 ruling**: resize reuses this exact choice, so resize cents
  are identical to destroy-and-recreate, and the clock is
  per-allocation-era — a resize kills the old clock with the old
  allocation and starts a fresh one.

  Plain module, not a `Change`: two writers share it (DeriveFromAppVersion
  at create, ResizePricing at resize), so it sits at the boundary.
  """

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Pricing

  @grandfather_years 1

  @typedoc "The pricing triple + clock an instance row carries."
  @type pricing :: %{
          size_id: term() | nil,
          monthly_cents: non_neg_integer() | nil,
          stopped_monthly_cents: non_neg_integer() | nil,
          grandfathered_until: DateTime.t() | nil
        }

  @doc """
  The snapshot for `allocation` under `version`'s catalog, clocked from
  `now`. The recommended_size loads `authorize?: false` — catalog rows
  are signed-in-readable and both callers are system paths (the create's
  derive and the member-gated resize).
  """
  @spec snapshot(
          allocation :: %{cpu_cores: Decimal.t(), memory_mb: integer(), storage_gb: integer()},
          version :: AppVersion.t(),
          now :: DateTime.t()
        ) ::
          pricing()
  def snapshot(allocation, version, now) do
    size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

    if custom_allocation?(allocation, version) do
      formula_price(allocation, now)
    else
      size_price(size, now)
    end
  end

  # A custom allocation: any dimension differs from the version's
  # defaults (the caller passes the effective allocation — chosen dims
  # over defaults at create, effective values at resize).
  defp custom_allocation?(allocation, version) do
    cpu_off = not Decimal.eq?(allocation.cpu_cores, version.default_cpu_cores)
    memory_off = allocation.memory_mb != version.default_memory_mb
    storage_off = allocation.storage_gb != version.default_storage_gb

    cpu_off or memory_off or storage_off
  end

  defp size_price(nil, _now),
    do: %{size_id: nil, monthly_cents: nil, stopped_monthly_cents: nil, grandfathered_until: nil}

  defp size_price(size, now) do
    %{
      size_id: size.id,
      monthly_cents: size.monthly_cents,
      stopped_monthly_cents: size.stopped_monthly_cents,
      grandfathered_until: grace_clock(now)
    }
  end

  defp formula_price(allocation, now) do
    rates = Pricing.price_allocation(allocation)

    %{
      size_id: nil,
      monthly_cents: rates.monthly_cents,
      stopped_monthly_cents: rates.stopped_monthly_cents,
      grandfathered_until: grace_clock(now)
    }
  end

  defp grace_clock(now), do: DateTime.shift(now, year: @grandfather_years)
end
