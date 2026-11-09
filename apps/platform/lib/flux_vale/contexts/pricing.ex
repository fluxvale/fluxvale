defmodule FluxVale.Pricing do
  @moduledoc """
  Pricing: the compute classes and the per-GB storage axis behind
  ADR-0028's flat monthly rate ("Kavita: $X/mo, done", #125, storage
  decoupled by #558) and — since the checkout tax layer (#138,
  ADR-0029 Am. 3 gate 2) — the per-country VAT rate table the checkout
  resolves against. Reads are any signed-in actor (the price shows in
  every catalog/provisioning surface); mutation is platform-admin-only.
  Opts into AshAdmin (ADR-0027) like Catalog: price and rate changes
  are business data — admin-editable, and the tax rates ship as YAML
  seed diffs (rate changes land as reviewable edits, per the settled
  #138 stance).
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  alias FluxVale.Pricing.Operations

  admin do
    show?(true)
  end

  # The paper-trail seam (#645, ADR-0048): versioned resources' Version
  # modules join the domain here so codegen migrates them and reads see
  # them. The console registry excludes them by name — the audit trail
  # surfaces in its own section, not as raw tables.
  paper_trail do
    include_versions?(true)
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
  both price through this one call. Since #558 the compute and
  storage axes round independently: monthly is the compute rate plus
  the storage rate, stopped is the storage rate alone (see
  `storage_monthly_cents/1`). `region` selects the v5 regional
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
  The storage axis rate (#558): the curve's per-GB pricing, unchanged
  — the storage term at `storage_gb` in whole cents. This is the
  stopped fee at any storage, and the storage component every running
  rate carries; a compute class prices none of it.
  """
  @spec storage_monthly_cents(non_neg_integer()) :: non_neg_integer()
  def storage_monthly_cents(storage_gb) when is_integer(storage_gb) and storage_gb >= 0 do
    Operations.PriceAllocation.storage_cents(storage_gb, :nuremberg)
  end

  @doc """
  The rates a version's recommendation carries (#558): the
  recommended compute class's monthly rate plus the storage axis at
  the version's own honest `default_storage_gb` — stopped is the
  storage alone. `version` is version-shaped (a map reading
  `recommended_size` — loaded — and `default_storage_gb`) so Pricing
  stays decoupled from the AppVersion struct. nil on a sizeless
  version: the unpriced drift shape, and billing never guesses.
  """
  @spec version_rates(map()) ::
          %{monthly_cents: non_neg_integer(), stopped_monthly_cents: non_neg_integer()} | nil
  def version_rates(version) do
    case version.recommended_size do
      nil ->
        nil

      size ->
        storage = storage_monthly_cents(version.default_storage_gb)

        %{monthly_cents: size.monthly_cents + storage, stopped_monthly_cents: storage}
    end
  end

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
  The ladder floor in cents (#398): the cheapest published compute
  class's monthly rate — the "from" price every catalog card shows
  (compute only since #558; the storage axis prices per GB on top).
  Computed over the public Size read on every call (never a literal),
  so admin reprices move every card; nil on an empty table (unseeded
  dev/test) — the surfaces hide the line.
  """
  @spec from_price_cents() :: non_neg_integer() | nil
  def from_price_cents do
    sizes =
      FluxVale.Pricing.Size
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> Ash.read!()

    case sizes do
      [] ->
        nil

      _seeded ->
        cheapest = Enum.min_by(sizes, & &1.monthly_cents)
        cheapest.monthly_cents
    end
  end

  @doc """
  The rates an instance settles at — the one resolver (#153: settle's
  `perform_settle` and the runway projection price through it, so the
  warning fires on the rate the wallet actually bleeds at): the
  creation-time `grandfathered_*` snapshot while `grandfathered_until`
  stands, then the live Size row by the snapshotted `size_id` (#134,
  settled on #121) — since #558 the size prices the compute axis and
  the storage axis prices per GB at the instance's own `storage_gb`
  (`storage_monthly_cents/1`). A custom allocation carries no size
  (#186) — after the grace it prices by the live anchor formula from
  the instance's own allocation. `instance` is instance-shaped (a map
  reading `size_id`, `grandfathered_*`, `cpu_cores`, `memory_mb`,
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
        live_rates(instance)
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

  defp live_rates(instance) do
    case Ash.get(FluxVale.Pricing.Size, instance.size_id, authorize?: false) do
      {:ok, size} ->
        # #558: the size row prices the compute axis only; storage
        # prices per GB at the instance's own GB — so an admin
        # compute reprice reaches this instance while its storage
        # rate always tracks the live axis.
        storage = storage_monthly_cents(instance.storage_gb)

        {:ok, %{running: size.monthly_cents + storage, stopped: storage}}

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
