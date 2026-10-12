defmodule FluxVale.Billing.Operations.GrantCreditsTest do
  @moduledoc """
  System-issued credits (#120): the welcome-grant posting surface (#122
  wires the signup call).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.TestSupport.BillingFixtures

  test "posts a welcome credit against the wallet" do
    {org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert {:ok, entry} = Billing.grant_credits(org, 300)

    assert entry.type == :credit
    assert entry.amount == 300
    assert entry.reason == :welcome
    assert entry.wallet_id == wallet.id

    assert {:ok, 300} = Billing.balance(wallet, authorize?: false)
  end

  test "accepts a wallet directly and a custom reason" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert {:ok, entry} = Billing.grant_credits(wallet, 50, reason: :adjustment)

    assert entry.reason == :adjustment
  end

  test "non-positive amounts are rejected loudly" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert_raise FunctionClauseError, fn -> Billing.grant_credits(wallet, 0) end
    assert_raise FunctionClauseError, fn -> Billing.grant_credits(wallet, -5) end
  end

  test "an idempotency key replays to the same entry" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, first} = Billing.grant_credits(wallet, 300, idempotency_key: "welcome-1")
    {:ok, replay} = Billing.grant_credits(wallet, 300, idempotency_key: "welcome-1")

    assert replay.id == first.id
    assert {:ok, 300} = Billing.balance(wallet, authorize?: false)
  end
end
