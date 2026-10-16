defmodule FluxVale.Billing.Operations.CreditWalletTest do
  @moduledoc """
  Externally funded credits (#120): the M6 payment webhook's posting
  surface — replay-safety by payment-derived idempotency key.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.TestSupport.BillingFixtures

  test "posts a purchase credit; the org target provisions on demand" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert {:ok, entry} = Billing.credit_wallet(org, 500, idempotency_key: "hitpay_pay_1")

    assert entry.type == :credit
    assert entry.amount == 500
    assert entry.reason == :purchase
  end

  test "a retried payment replays to the same entry — never a double credit" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, first} = Billing.credit_wallet(wallet, 500, idempotency_key: "hitpay_pay_1")
    {:ok, replay} = Billing.credit_wallet(wallet, 500, idempotency_key: "hitpay_pay_1")

    assert replay.id == first.id
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
  end

  test "non-positive amounts are rejected loudly" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert_raise FunctionClauseError, fn -> Billing.credit_wallet(wallet, 0) end
  end

  test "the charge's tax fields ride the credit onto the ledger row" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert {:ok, entry} =
             Billing.credit_wallet(wallet, 500,
               idempotency_key: "hitpay_pay_9",
               fields: %{billing_country: "SG", applied_rate: 900}
             )

    assert entry.billing_country == "SG"
    assert entry.applied_rate == 900
  end
end
