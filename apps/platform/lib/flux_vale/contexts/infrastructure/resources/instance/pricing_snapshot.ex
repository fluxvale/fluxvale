defmodule FluxVale.Infrastructure.Instance.PricingSnapshot do
  @moduledoc """
  The one pricing-snapshot choice (#121/#186, shared per #493, storage
  decoupled per #558): given an allocation, the AppVersion it came
  from, and now — what the instance row's pricing triple is.

  - Compute at the version's recommendation (CPU and memory on its
    defaults, whatever the storage is) the recommended `Size` row
    snapshots: `size_id` plus the compute class's monthly rate with
    the storage axis's per-GB rate added at the row's own GB. A
    sizeless recommendation → unpriced (all nil — billing never
    guesses; the pre-#125 drift shape).
  - Compute off → the anchor formula's cents
    (`Pricing.price_allocation/1`), no size.

  Storage never moves an instance off its size (#558): the axis
  prices independently, so its per-GB rate rides whichever arm the
  compute chose.

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
      size_price(size, allocation.storage_gb, now)
    end
  end

  # A custom allocation: compute differs from the version's defaults
  # (the caller passes the effective allocation — chosen dims over
  # defaults at create, effective values at resize). Storage is not a
  # defection (#558): the axis prices independently, so a storage
  # choice keeps the size snapshot.
  defp custom_allocation?(allocation, version) do
    cpu_off = not Decimal.eq?(allocation.cpu_cores, version.default_cpu_cores)
    memory_off = allocation.memory_mb != version.default_memory_mb

    cpu_off or memory_off
  end

  defp size_price(nil, _storage_gb, _now),
    do: %{size_id: nil, monthly_cents: nil, stopped_monthly_cents: nil, grandfathered_until: nil}

  defp size_price(size, storage_gb, now) do
    storage = Pricing.storage_monthly_cents(storage_gb)

    %{
      size_id: size.id,
      monthly_cents: size.monthly_cents + storage,
      stopped_monthly_cents: storage,
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
