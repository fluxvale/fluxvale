defmodule FluxVale.Billing.Operations.TaxSummaryTest do
  @moduledoc """
  The quarterly per-country tax summary (#139, ADR-0029 Am. 3 gate 3):
  the period's tax-bearing entries grouped by billing country — and by
  state within the US — summing the net and the collected tax, signed
  by entry type (charge +, refund −). A return is a query, not a
  reconstruction.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)
    %{wallet: wallet}
  end

  test "groups the period's charge credits by country, summing the collected tax", %{
    wallet: wallet
  } do
    {from, to} = current_month()
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000, tax: 200)
    charge!(wallet, 1000, country: "DE", rate: 1900, tax: 190)

    assert summary!(from, to) == [
             %{
               country: "DE",
               state: nil,
               applied_rate: 1900,
               reverse_charge?: false,
               net_cents: 1000,
               tax_cents: 190
             },
             %{
               country: "US",
               state: "CA",
               applied_rate: 2000,
               reverse_charge?: false,
               net_cents: 1000,
               tax_cents: 200
             }
           ]
  end

  test "splits the US by billing state; other countries group by country alone", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 500, country: "US", state: "CA", rate: 2000, tax: 100)
    charge!(wallet, 833, country: "US", state: "NY", rate: 2000, tax: 167)
    charge!(wallet, 250, country: "GB", rate: 2000, tax: 50)

    rows = summary!(from, to)

    assert Enum.map(rows, &{&1.country, &1.state, &1.net_cents, &1.tax_cents}) == [
             {"GB", nil, 250, 50},
             {"US", "CA", 500, 100},
             {"US", "NY", 833, 167}
           ]
  end

  # The persisted tax is summed, never re-derived: the group's tax is
  # the stored tax_cents of its entries, whatever a recomputation from
  # net * rate would say.
  test "sums the persisted collected tax over the period", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 500, country: "US", state: "CA", rate: 1900, tax: 95)
    charge!(wallet, 1000, country: "US", state: "CA", rate: 1900, tax: 190)

    # The discriminating fixture (#260): 80 is not 19% of 500, so an
    # implementation that re-derives tax from net * rate would answer
    # 95 for this row (and 380 for the sum) instead of the stored 80
    # (365). The first two fixtures alone alias at exactly 19% and
    # cannot tell summing from re-deriving.
    charge!(wallet, 500, country: "US", state: "CA", rate: 1900, tax: 80)

    assert [%{net_cents: 2000, tax_cents: 365}] = summary!(from, to)
  end

  test "keeps reverse-charge rows apart from untaxed consumer rows", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 1000, country: "DE", rate: 0, tax: 0)
    charge!(wallet, 1000, country: "DE", rate: 0, tax: 0, reverse_charge?: true)

    rows = summary!(from, to)

    assert Enum.map(rows, &{&1.reverse_charge?, &1.net_cents, &1.tax_cents}) == [
             {false, 1000, 0},
             {true, 1000, 0}
           ]
  end

  test "a US row without a billing state is its own bucket, never merged into a state's total", %{
    wallet: wallet
  } do
    {from, to} = current_month()
    charge!(wallet, 500, country: "US", state: nil, rate: 2000, tax: 100)
    charge!(wallet, 700, country: "US", state: "CA", rate: 2000, tax: 140)

    rows = summary!(from, to)

    assert Enum.map(rows, &{&1.state, &1.net_cents, &1.tax_cents}) == [
             {nil, 500, 100},
             {"CA", 700, 140}
           ]
  end

  test "nets a charge and its reversal to zero per group (net and tax)", %{wallet: wallet} do
    {from, to} = current_month()

    {:ok, charge} =
      Billing.credit_wallet(wallet, 1000,
        idempotency_key: "hitpay_refunded",
        reason: :purchase,
        fields: %{
          billing_country: "US",
          billing_state: "CA",
          applied_rate: 2000,
          tax_cents: 200
        }
      )

    assert {:ok, _refund} = Billing.reverse_entry(charge)

    assert [%{net_cents: 0, tax_cents: 0}] = summary!(from, to)
  end

  # The compensating debit is matched by reverses_id, not reason — a
  # reversal under an overridden reason still copies the tax facts and
  # must still net out of the return.
  test "nets out a taxed purchase reversed under an overridden reason", %{wallet: wallet} do
    {from, to} = current_month()

    {:ok, charge} =
      Billing.credit_wallet(wallet, 1000,
        idempotency_key: "hitpay_adjusted",
        reason: :purchase,
        fields: %{
          billing_country: "US",
          billing_state: "CA",
          applied_rate: 2000,
          tax_cents: 200
        }
      )

    assert {:ok, _refund} = Billing.reverse_entry(charge, reason: :adjustment)

    assert [%{net_cents: 0, tax_cents: 0}] = summary!(from, to)
  end

  # A refund's own reversal is a CREDIT with reverses_id (#260): the
  # restored net and tax must land in the summary again — the filter
  # admits reversal credits, not just purchase credits (the credit
  # half was reason-gated and dropped the restored tax).
  test "nets refund debits and their reversals symmetrically", %{wallet: wallet} do
    {from, to} = current_month()

    {:ok, charge} =
      Billing.credit_wallet(wallet, 1000,
        idempotency_key: "hitpay_refund_reversed",
        reason: :purchase,
        fields: %{
          billing_country: "US",
          billing_state: "CA",
          applied_rate: 2000,
          tax_cents: 200
        }
      )

    assert {:ok, refund} = Billing.reverse_entry(charge)
    assert [%{net_cents: 0, tax_cents: 0}] = summary!(from, to)

    assert {:ok, _restored} = Billing.reverse_entry(refund)
    assert [%{net_cents: 1000, tax_cents: 200}] = summary!(from, to)
  end

  test "excludes non-tax postings and rows without persisted tax facts", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000, tax: 200)

    # a grant posts a credit with no tax facts; a purchase with no
    # country (pre-tax-layer history), a purchase with no rate, and an
    # old-style refund without copied facts are all unattributable
    {:ok, _grant} = Billing.grant_credits(wallet, 500, reason: :adjustment)

    {:ok, _uncountryed} =
      LedgerEntry.create(
        %{wallet_id: wallet.id, amount: 300, type: :credit, reason: :purchase},
        authorize?: false
      )

    {:ok, _unrated} =
      LedgerEntry.create(
        %{
          wallet_id: wallet.id,
          amount: 300,
          type: :credit,
          reason: :purchase,
          billing_country: "FR"
        },
        authorize?: false
      )

    {:ok, _fieldless_refund} =
      LedgerEntry.create(
        %{wallet_id: wallet.id, amount: -300, type: :debit, reason: :refund},
        authorize?: false
      )

    assert [%{country: "US", net_cents: 1000}] = summary!(from, to)
  end

  test "confines the summary to the requested range (half-open, both endpoints as days)", %{
    wallet: wallet
  } do
    today = Date.utc_today()
    midnight = DateTime.new!(today, ~T[00:00:00])
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000, tax: 200)

    # backdated before the window; a row stamped exactly at the window's
    # exclusive end (tomorrow 00:00 UTC) also stays out
    charge!(wallet, 400, [country: "US", state: "CA", rate: 2000, tax: 80],
      posted_at: DateTime.add(midnight, -86_400)
    )

    charge!(wallet, 400, [country: "US", state: "CA", rate: 2000, tax: 80],
      posted_at: DateTime.add(midnight, 86_400)
    )

    assert [%{net_cents: 1000, tax_cents: 200}] = summary!(today, today)
  end

  test "scopes the summary to the actor's org like every ledger read", %{wallet: wallet} do
    member = org_member(wallet)
    {from, to} = current_month()
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000, tax: 200)

    {_other_org, other_wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)
    charge!(other_wallet, 700, country: "DE", rate: 1900, tax: 133)
    other_member = org_member(other_wallet)

    assert [%{country: "US"}] = summary!(from, to, actor: member, authorize?: true)
    assert [%{country: "DE"}] = summary!(from, to, actor: other_member, authorize?: true)

    stranger = AccountsFixtures.user!()
    assert [] = summary!(from, to, actor: stranger, authorize?: true)

    # no actor, no bypass — the default posture forbids
    assert {:error, _forbidden} = Billing.tax_summary(from, to)
  end

  # System posture by default (put_new — an explicit authorize? wins,
  # which is how the scoping test exercises the policy path).
  defp summary!(from, to, opts \\ []) do
    opts = Keyword.put_new(opts, :authorize?, false)

    assert {:ok, rows} = Billing.tax_summary(from, to, opts)
    rows
  end

  defp current_month do
    today = Date.utc_today()
    {Date.beginning_of_month(today), Date.end_of_month(today)}
  end

  # A charge credit with the tax facts a completed top-up persists. A
  # timestamp outside the current window is a precondition no action
  # accepts — forced on the create changeset (the action itself runs,
  # so validations still gate the row).
  defp charge!(wallet, amount_cents, fields, opts \\ []) do
    base =
      Ash.Changeset.for_create(
        LedgerEntry,
        :create,
        %{
          wallet_id: wallet.id,
          amount: amount_cents,
          type: :credit,
          reason: :purchase,
          idempotency_key: "hitpay_#{System.unique_integer([:positive])}",
          billing_country: fields[:country],
          billing_state: fields[:state],
          applied_rate: fields[:rate],
          tax_cents: fields[:tax],
          reverse_charge?: fields[:reverse_charge?] || false
        },
        authorize?: false
      )

    changeset =
      case Keyword.fetch(opts, :posted_at) do
        {:ok, at} -> Ash.Changeset.force_change_attribute(base, :created_at, at)
        :error -> base
      end

    Ash.create!(changeset)
  end

  defp org_member(wallet) do
    wallet
    |> Ash.load!([organization: [:members]], authorize?: false)
    |> Map.get(:organization)
    |> Map.get(:members)
    |> List.first()
  end
end
