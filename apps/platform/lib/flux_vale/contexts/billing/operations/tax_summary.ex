defmodule FluxVale.Billing.Operations.TaxSummary do
  @moduledoc """
  The quarterly per-country tax summary (ADR-0029 Am. 3 gate 3) — a
  return is a query, not a reconstruction: the period's charge credits
  (reason `:purchase`, the rows carrying the checkout tax layer's
  fields) grouped by billing country, and by billing state within the
  US (Am. 3: state-level totals are the US economic-nexus monitor).

  Each row sums the NET wallet credits (the gateway charge is gross =
  net + tax) and derives the tax from the persisted applied rate:
  round(net * rate / 10_000), half-up — the same rounding the tax layer
  applies at charge time. Rate and country ride the group key, so every
  row's derivation sits on a single persisted rate. Rows without a
  persisted country or rate can't be attributed to a return and are
  excluded (`:tax_charges`'s filter). Read only, over the append-only
  ledger; actor-scoped like every ledger read.
  """

  alias FluxVale.Billing.LedgerEntry

  @basis_points 10_000
  # Integer half-up for non-negative values: add half the divisor, then
  # truncate — no float ever touches the money.
  @half_divisor 5_000
  @us "US"

  @spec call(Date.t(), Date.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def call(from, to, opts \\ []) when is_struct(from, Date) and is_struct(to, Date) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, charges} <- charges_in_range(from, to, actor, authorize?) do
      {:ok, summarize(charges)}
    end
  end

  # Inclusive of both endpoint days: `to` expands to the start of the
  # following day (the range stays half-open, matching :tax_charges).
  defp charges_in_range(from, to, actor, authorize?) do
    query =
      Ash.Query.for_read(
        LedgerEntry,
        :tax_charges,
        %{from: day_start(from), to: day_after(to)},
        actor: actor,
        authorize?: authorize?
      )

    Ash.read(query)
  end

  defp day_start(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp day_after(date) do
    date
    |> Date.add(1)
    |> day_start()
  end

  defp summarize(charges) do
    charges
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {{country, state, rate}, entries} ->
      net =
        entries
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      %{
        country: country,
        state: state,
        applied_rate: rate,
        net_cents: net,
        tax_cents: tax(net, rate)
      }
    end)
    |> Enum.sort_by(&{&1.country, &1.state || "", &1.applied_rate})
  end

  # State differentiates only within the US (Am. 3) — a non-US row's
  # billing state (if one ever leaked in) folds into its country total.
  defp group_key(entry) do
    state = if entry.billing_country == @us, do: entry.billing_state

    {entry.billing_country, state, entry.applied_rate}
  end

  defp tax(net_cents, rate), do: div(net_cents * rate + @half_divisor, @basis_points)
end
