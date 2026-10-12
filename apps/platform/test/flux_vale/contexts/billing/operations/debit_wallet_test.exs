defmodule FluxVale.Billing.Operations.DebitWalletTest do
  @moduledoc """
  Consumption posting (#120): whole cents on the ledger, fractional
  remainder pooled in the wallet carryover, idempotent replays, and the
  per-wallet advisory lock keeping concurrent debits from losing updates.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Repo
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 10_000)
    %{wallet: wallet}
  end

  test "posts whole cents from a micro-cent amount", %{wallet: wallet} do
    assert {:ok, entry} = Billing.debit_wallet(wallet, 20_000)

    assert entry.type == :debit
    assert entry.amount == -2
    assert entry.reason == :usage

    assert {:ok, 9_998} = Billing.balance(wallet, authorize?: false)
    assert Repo.reload!(wallet).carryover == 0
  end

  test "a sub-cent debit posts no ledger row — the fraction pools", %{wallet: wallet} do
    assert {:ok, :accrued} = Billing.debit_wallet(wallet, 7_500)

    assert {:ok, 10_000} = Billing.balance(wallet, authorize?: false)
    assert Repo.reload!(wallet).carryover == 7_500
  end

  test "carryover accumulates across debits until it rounds out", %{wallet: wallet} do
    {:ok, :accrued} = Billing.debit_wallet(wallet, 7_500)
    {:ok, entry} = Billing.debit_wallet(wallet, 7_500)

    # 7_500µ + 7_500µ = 1.5¢ → one cent posts, half a cent pools
    assert entry.amount == -1
    assert {:ok, 9_999} = Billing.balance(wallet, authorize?: false)
    assert Repo.reload!(wallet).carryover == 5_000
  end

  test "an idempotent replay returns the original entry, not a second debit", %{wallet: wallet} do
    {:ok, first} = Billing.debit_wallet(wallet, 20_000, idempotency_key: "settle:i-1")
    {:ok, replay} = Billing.debit_wallet(wallet, 20_000, idempotency_key: "settle:i-1")

    assert replay.id == first.id
    assert {:ok, 9_998} = Billing.balance(wallet, authorize?: false)
  end

  test "an org target resolves the wallet on demand" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 1_000)

    assert {:ok, entry} = Billing.debit_wallet(org, 10_000)

    assert entry.amount == -1
  end

  test "reason is :usage by default and overridable (refund debits)", %{wallet: wallet} do
    {:ok, usage} = Billing.debit_wallet(wallet, 10_000)
    {:ok, refund} = Billing.debit_wallet(wallet, 10_000, reason: :refund)

    assert usage.reason == :usage
    assert refund.reason == :refund
  end

  test "non-positive micro-cent amounts are rejected loudly", %{wallet: wallet} do
    assert_raise FunctionClauseError, fn -> Billing.debit_wallet(wallet, 0) end
  end
end
