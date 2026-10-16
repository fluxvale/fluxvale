defmodule FluxVale.Billing.Operations.TaxSummaryTest do
  @moduledoc """
  The quarterly per-country tax summary (#139, ADR-0029 Am. 3 gate 3):
  the period's charge credits grouped by billing country — and by state
  within the US — with tax derived half-up from the persisted applied
  rate. A return is a query, not a reconstruction.
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

  test "groups the period's charge credits by country, deriving tax from the applied rate", %{
    wallet: wallet
  } do
    {from, to} = current_month()
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000)
    charge!(wallet, 1000, country: "DE", rate: 1900)

    assert summary!(from, to) == [
             %{country: "DE", state: nil, applied_rate: 1900, net_cents: 1000, tax_cents: 190},
             %{country: "US", state: "CA", applied_rate: 2000, net_cents: 1000, tax_cents: 200}
           ]
  end

  test "splits the US by billing state; other countries group by country alone", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 500, country: "US", state: "CA", rate: 2000)
    charge!(wallet, 833, country: "US", state: "NY", rate: 2000)
    charge!(wallet, 250, country: "GB", rate: 2000)

    rows = summary!(from, to)

    assert Enum.map(rows, &{&1.country, &1.state, &1.net_cents, &1.tax_cents}) == [
             {"GB", nil, 250, 50},
             {"US", "CA", 500, 100},
             {"US", "NY", 833, 167}
           ]
  end

  # 25 * 1000 / 10_000 = 2.5 — the .5 lands up, integer math (no float
  # ever touches the derivation).
  test "rounds the derived tax half-up at the boundary", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 25, country: "US", state: "TX", rate: 1000)

    assert [%{tax_cents: 3}] = summary!(from, to)
  end

  test "sums a country-state-rate group's charges into one row", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 400, country: "US", state: "CA", rate: 2000)
    charge!(wallet, 600, country: "US", state: "CA", rate: 2000)

    assert [%{net_cents: 1000, tax_cents: 200}] = summary!(from, to)
  end

  test "excludes non-charge postings and rows without persisted tax facts", %{wallet: wallet} do
    {from, to} = current_month()
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000)

    # a grant posts a credit with no tax facts; a purchase with no
    # country (pre-tax-layer history) and a purchase with no rate are
    # equally unattributable to a return
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

    assert [%{country: "US", net_cents: 1000}] = summary!(from, to)
  end

  test "confines the summary to the requested range (half-open, both endpoints as days)", %{
    wallet: wallet
  } do
    today = Date.utc_today()
    midnight = DateTime.new!(today, ~T[00:00:00])
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000)

    # backdated before the window; a row stamped exactly at the window's
    # exclusive end (tomorrow 00:00 UTC) also stays out
    charge!(wallet, 400, [country: "US", state: "CA", rate: 2000],
      posted_at: DateTime.add(midnight, -86_400)
    )

    charge!(wallet, 400, [country: "US", state: "CA", rate: 2000],
      posted_at: DateTime.add(midnight, 86_400)
    )

    assert [%{net_cents: 1000}] = summary!(today, today)
  end

  test "scopes the summary to the actor's org like every ledger read", %{wallet: wallet} do
    member = org_member(wallet)
    {from, to} = current_month()
    charge!(wallet, 1000, country: "US", state: "CA", rate: 2000)

    {_other_org, other_wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)
    charge!(other_wallet, 700, country: "DE", rate: 1900)
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
    changeset =
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
          applied_rate: fields[:rate]
        },
        authorize?: false
      )

    changeset =
      case Keyword.fetch(opts, :posted_at) do
        {:ok, at} -> Ash.Changeset.force_change_attribute(changeset, :created_at, at)
        :error -> changeset
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
