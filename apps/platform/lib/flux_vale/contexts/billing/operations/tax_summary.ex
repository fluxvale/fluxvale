defmodule FluxVale.Billing.Operations.TaxSummary do
  @moduledoc """
  The quarterly per-country tax summary (ADR-0029 Am. 3 gate 3) — a
  return is a query, not a reconstruction: the period's tax-bearing
  entries (charge credits and, copied by ReverseEntry, the refund
  debits that reverse them) grouped by billing country, billing state
  within the US, applied rate, and reverse-charge marker. The marker
  rides the group key so OSS consumer nets are never inflated by B2B
  reverse-charge rows.

  Each row sums the NET wallet credits (signed — credit positive,
  refund negative) and the collected `tax_cents`, signed the same way:
  the ledger stores the tax as a non-negative magnitude, the entry's
  type carries the sign. Nothing is re-derived — the figure is the sum
  of what was collected and un-collected in the period. Country, state,
  rate, and marker ride the group key, so every row's figures sit on a
  single persisted rate. Rows without a persisted country or rate
  can't be attributed to a return and are excluded
  (`:tax_bearing_entries`'s filter). Read only, over the append-only
  ledger; actor-scoped like every ledger read.
  """

  alias FluxVale.Billing.LedgerEntry

  @us "US"

  @spec call(Date.t(), Date.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def call(from, to, opts \\ []) when is_struct(from, Date) and is_struct(to, Date) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, entries} <- tax_bearing_in_range(from, to, actor, authorize?) do
      {:ok, summarize(entries)}
    end
  end

  # Inclusive of both endpoint days: `to` expands to the start of the
  # following day (the range stays half-open, matching
  # :tax_bearing_entries).
  defp tax_bearing_in_range(from, to, actor, authorize?) do
    query =
      Ash.Query.for_read(
        LedgerEntry,
        :tax_bearing_entries,
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

  defp summarize(entries) do
    entries
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {{country, state, rate, reverse_charge?}, entries} ->
      net =
        entries
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      tax =
        entries
        |> Enum.map(&signed_tax/1)
        |> Enum.sum()

      %{
        country: country,
        state: state,
        applied_rate: rate,
        reverse_charge?: reverse_charge?,
        net_cents: net,
        tax_cents: tax
      }
    end)
    |> Enum.sort_by(&{&1.country, &1.state || "", &1.applied_rate, &1.reverse_charge?})
  end

  # State differentiates only within the US (Am. 3) — a non-US row's
  # billing state (if one ever leaked in) folds into its country total.
  # A nil state (US rows the checkout couldn't attribute) stays its own
  # bucket: nil never merges into a state's total.
  defp group_key(entry) do
    state = if entry.billing_country == @us, do: entry.billing_state

    {entry.billing_country, state, entry.applied_rate, entry.reverse_charge?}
  end

  # tax_cents is a magnitude on the row; the entry's type carries the
  # sign (credit collected, debit refunded).
  defp signed_tax(%LedgerEntry{type: :credit, tax_cents: tax}), do: tax || 0
  defp signed_tax(%LedgerEntry{type: :debit, tax_cents: tax}), do: -(tax || 0)
end
