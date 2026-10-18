defmodule FluxVale.Billing.Operations.PostEntryTest do
  @moduledoc """
  The internal posting seam's own contract (#120): direction derived from
  type (sign applied, never trusted from the caller) and the guard the
  posting operations rely on. Public callers go through
  grant/credit/debit/reverse — this module is domain-internal.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing.Operations.PostEntry
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)
    %{wallet: wallet}
  end

  test "applies the sign from type — a caller cannot invert a posting", %{wallet: wallet} do
    assert {:ok, credit} = PostEntry.call(wallet, :credit, 100, :adjustment)
    assert credit.amount == 100

    assert {:ok, debit} = PostEntry.call(wallet, :debit, 100, :adjustment)
    assert debit.amount == -100
  end

  test "rejects malformed posts loudly (the internal-caller contract)" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert_raise FunctionClauseError, fn ->
      PostEntry.call(wallet, :uncredit, 100, :adjustment)
    end

    assert_raise FunctionClauseError, fn ->
      PostEntry.call(wallet, :credit, -100, :adjustment)
    end

    assert_raise FunctionClauseError, fn ->
      PostEntry.call(wallet, :credit, 0, :adjustment)
    end
  end

  test "carries the fields map onto the created row; keyless posts keep null tax facts", %{
    wallet: wallet
  } do
    assert {:ok, charged} =
             PostEntry.call(wallet, :credit, 500, :purchase,
               fields: %{
                 billing_country: "US",
                 billing_state: "CA",
                 applied_rate: 2000,
                 tax_cents: 100,
                 reverse_charge?: false
               }
             )

    assert charged.billing_country == "US"
    assert charged.billing_state == "CA"
    assert charged.applied_rate == 2000
    assert charged.tax_cents == 100
    assert charged.reverse_charge? == false

    assert {:ok, bare} = PostEntry.call(wallet, :credit, 100, :adjustment)
    assert bare.billing_country == nil
    assert bare.billing_state == nil
    assert bare.applied_rate == nil
    assert bare.tax_cents == nil
    # the marker is schema-defaulted, not null — the group key's shape
    assert bare.reverse_charge? == false
  end

  test "a replayed keyed post returns the original row, fields untouched", %{wallet: wallet} do
    fields = %{billing_country: "DE", applied_rate: 1900}

    assert {:ok, first} =
             PostEntry.call(wallet, :credit, 500, :purchase,
               idempotency_key: "hitpay_pay_1",
               fields: fields
             )

    assert {:ok, replay} =
             PostEntry.call(wallet, :credit, 500, :purchase,
               idempotency_key: "hitpay_pay_1",
               fields: %{billing_country: "FR", applied_rate: 0}
             )

    assert replay.id == first.id
    assert replay.billing_country == "DE"
  end
end
