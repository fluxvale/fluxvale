defmodule FluxVale.Pricing do
  @moduledoc """
  Pricing: the priceable allocation sizes behind ADR-0028's flat monthly
  rate ("Kavita: $X/mo, done", #125). Reads are any signed-in actor (the
  price shows in every catalog/provisioning surface); mutation is
  platform-admin-only. Opts into AshAdmin (ADR-0027) like Catalog:
  price changes are business data, admin-editable without a deploy.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource FluxVale.Pricing.Size
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
  The rates an instance settles at — the one resolver (#153: settle's
  `perform_settle` and the runway projection price through it, so the
  warning fires on the rate the wallet actually bleeds at): the
  creation-time `grandfathered_*` snapshot while `grandfathered_until`
  stands, then the live Size row by the snapshotted `size_id` (#134,
  settled on #121). `instance` is instance-shaped (a map reading
  `size_id` + `grandfathered_*`) so Pricing stays decoupled from the
  Instance struct. `{:ok, nil}` is an unpriced instance (no size —
  pre-#121 drift): settle forgives the time, runway burns nothing
  for it.
  """
  @spec settlement_rates(map(), DateTime.t()) ::
          {:ok, %{running: non_neg_integer(), stopped: non_neg_integer()} | nil}
          | {:error, term()}
  def settlement_rates(instance, now) do
    cond do
      is_nil(instance.size_id) ->
        {:ok, nil}

      grandfathered?(instance, now) ->
        {:ok,
         %{
           running: instance.grandfathered_monthly_cents,
           stopped: instance.grandfathered_stopped_monthly_cents
         }}

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
