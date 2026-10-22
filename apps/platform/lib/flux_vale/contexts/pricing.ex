defmodule FluxVale.Pricing do
  @moduledoc """
  Pricing: the priceable allocation sizes behind ADR-0028's flat monthly
  rate ("Kavita: $X/mo, done", #125) and — since the checkout tax layer
  (#138, ADR-0029 Am. 3 gate 2) — the per-country VAT rate table the
  checkout resolves against. Reads are any signed-in actor (the price
  shows in every catalog/provisioning surface); mutation is
  platform-admin-only. Opts into AshAdmin (ADR-0027) like Catalog:
  price and rate changes are business data — admin-editable, and the
  tax rates ship as YAML seed diffs (rate changes land as reviewable
  edits, per the settled #138 stance).
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  alias FluxVale.Pricing.Operations

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Pricing.Size)
    resource(FluxVale.Pricing.TaxRate)
  end

  @doc """
  Integer US cents → `"$12.34"` (1 credit = 1 US cent, docs/product.md;
  display currency pinned by ADR-0029 Am. 1).
  """
  @spec format_usd(non_neg_integer()) :: String.t()
  def format_usd(cents) when is_integer(cents) and cents >= 0 do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    formatted = :io_lib.format("~B.~2..0B", [dollars, remainder])
    body = IO.iodata_to_binary(formatted)

    "$" <> body
  end

  @doc """
  The VAT rate a checkout charges (`resolve_tax_rate/3` →
  `Operations.ResolveTaxRate`): the applied rate in basis points.
  """
  defdelegate resolve_tax_rate(country, state \\ nil, time \\ DateTime.utc_now()),
    to: Operations.ResolveTaxRate,
    as: :call

  @doc """
  ADR-0028's price = f(allocation) at ANY allocation (#186): the
  market-anchor curve behind the seeded table, in whole cents — the
  wizard's live estimate and the ledger's custom-allocation charge
  both price through this one call. `region` selects the v5 regional
  surcharge — the default lives HERE and nowhere else
  (`:nuremberg`, the one seeded region; `:singapore` on standby,
  unseeded).
  """
  @spec price_allocation(
          %{cpu_cores: Decimal.t(), memory_mb: pos_integer(), storage_gb: non_neg_integer()},
          atom()
        ) :: %{monthly_cents: non_neg_integer(), stopped_monthly_cents: non_neg_integer()}
  defdelegate price_allocation(allocation, region \\ :nuremberg),
    to: Operations.PriceAllocation,
    as: :call

  @doc """
  The customer-facing monthly-rate label (#206): the flat figure is a
  monthly-EQUIVALENT rate — billing accrues it µs-hourly against the
  wallet (`perform_settle`'s proration, #121), never as a monthly
  invoice. Every price surface states both, so "$X/mo" can't read as
  monthly billing.
  """
  @spec format_monthly_rate(non_neg_integer()) :: String.t()
  def format_monthly_rate(cents) when is_integer(cents) and cents >= 0 do
    format_usd(cents) <> "/mo · billed hourly"
  end

  @doc """
  The rates an instance settles at — the one resolver (#153: settle's
  `perform_settle` and the runway projection price through it, so the
  warning fires on the rate the wallet actually bleeds at): the
  creation-time `grandfathered_*` snapshot while `grandfathered_until`
  stands, then the live Size row by the snapshotted `size_id` (#134,
  settled on #121). A custom allocation carries no size (#186) — after
  the grace it prices by the live anchor formula from the instance's
  own allocation. `instance` is instance-shaped (a map reading
  `size_id`, `grandfathered_*`, `cpu_cores`, `memory_mb`,
  `storage_gb`) so Pricing stays decoupled from the Instance struct.
  `{:ok, nil}` is an unpriced instance (neither a size nor a formula
  snapshot — pre-#121 drift only): settle forgives the time, runway
  burns nothing for it.
  """
  @spec settlement_rates(map(), DateTime.t()) ::
          {:ok, %{running: non_neg_integer(), stopped: non_neg_integer()} | nil}
          | {:error, term()}
  def settlement_rates(instance, now) do
    cond do
      unpriced?(instance) ->
        {:ok, nil}

      grandfathered?(instance, now) and not is_nil(instance.grandfathered_monthly_cents) ->
        {:ok,
         %{
           running: instance.grandfathered_monthly_cents,
           stopped: instance.grandfathered_stopped_monthly_cents
         }}

      is_nil(instance.size_id) ->
        formula_rates(instance)

      true ->
        live_rates(instance.size_id)
    end
  end

  # A nil grandfathered_until prices live (safe default for any row the
  # backfill missed).
  defp grandfathered?(instance, now) do
    not is_nil(instance.grandfathered_until) and
      DateTime.compare(now, instance.grandfathered_until) == :lt
  end

  # Unpriced = nothing to price from: no size AND no formula snapshot —
  # the formula snapshot is the cents + clock pair, so a sizeless row
  # missing either stays forgiven (hand-built/AshAdmin shapes; the
  # derive writes them atomically). A sizeful row with nil cents inside
  # its grace prices live instead (the pre-backfill shape).
  defp unpriced?(instance) do
    is_nil(instance.size_id) and
      (is_nil(instance.grandfathered_until) or is_nil(instance.grandfathered_monthly_cents))
  end

  # A custom allocation past its grace: the live curve at the
  # instance's own allocation (instance-shaped input carries the
  # allocation fields; they are presence-validated at create and were
  # NOT NULL with defaults on all pre-#180 rows). The default region
  # prices it until the region-dimension lane wires instance regions.
  defp formula_rates(instance) do
    rates = price_allocation(instance)

    {:ok, %{running: rates.monthly_cents, stopped: rates.stopped_monthly_cents}}
  end

  defp live_rates(size_id) do
    case Ash.get(FluxVale.Pricing.Size, size_id, authorize?: false) do
      {:ok, size} ->
        {:ok, %{running: size.monthly_cents, stopped: size.stopped_monthly_cents}}

      # defensive: the instances → pricing_sizes FK has no ON DELETE, so
      # a missing row is data corruption — fail the caller, never price
      # a guess; not simulatable without dropping the constraint
      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end
end
