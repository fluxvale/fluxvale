defmodule FluxVale.Billing.Operations.ReverseEntryTest do
  @moduledoc """
  Refunds as compensating entries (#120): opposite-direction posting,
  reverses_id pairing, and the double-reversal guard.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 1_000)
    %{wallet: wallet}
  end

  test "reversing a credit posts the offsetting debit and restores the balance", %{
    wallet: wallet
  } do
    {:ok, purchase} = Billing.credit_wallet(wallet, 500, idempotency_key: "pay_r1")

    assert {:ok, reversal} = Billing.reverse_entry(purchase)

    assert reversal.type == :debit
    assert reversal.amount == -500
    assert reversal.reason == :refund
    assert reversal.reverses_id == purchase.id

    assert {:ok, 1_000} = Billing.balance(wallet, authorize?: false)
  end

  test "reversing a debit posts the offsetting credit (correcting an erroneous debit)", %{
    wallet: wallet
  } do
    {:ok, usage} = Billing.debit_wallet(wallet, 10_000)

    assert {:ok, reversal} = Billing.reverse_entry(usage)

    assert reversal.type == :credit
    assert reversal.amount == 1
    assert reversal.reason == :refund
    assert reversal.reverses_id == usage.id
  end

  test "a second reversal of the same entry is rejected", %{wallet: wallet} do
    {:ok, purchase} = Billing.credit_wallet(wallet, 500)
    {:ok, _first} = Billing.reverse_entry(purchase)

    assert {:error, :already_reversed} = Billing.reverse_entry(purchase)

    # and the books only moved once
    assert {:ok, 1_000} = Billing.balance(wallet, authorize?: false)
  end

  test "reason and idempotency key are overridable", %{wallet: wallet} do
    {:ok, purchase} = Billing.credit_wallet(wallet, 100)

    assert {:ok, reversal} =
             Billing.reverse_entry(purchase,
               reason: :adjustment,
               idempotency_key: "refund-1"
             )

    assert reversal.reason == :adjustment
    assert reversal.idempotency_key == "refund-1"
  end

  test "a keyed replay returns the original reversal", %{wallet: wallet} do
    {:ok, purchase} = Billing.credit_wallet(wallet, 100)

    {:ok, first} = Billing.reverse_entry(purchase, idempotency_key: "refund-2")
    {:ok, replay} = Billing.reverse_entry(purchase, idempotency_key: "refund-2")

    assert replay.id == first.id
  end

  test "a foreign idempotency key is rejected, not silently ignored", %{wallet: wallet} do
    {:ok, purchase} = Billing.credit_wallet(wallet, 100, idempotency_key: "pay_own")
    {:ok, other_purchase} = Billing.credit_wallet(wallet, 200, idempotency_key: "pay_other")

    assert {:error, :idempotency_key_mismatch} =
             Billing.reverse_entry(purchase, idempotency_key: "pay_other")

    # the refund never posted — nothing behind the acknowledgement
    assert {:ok, _reversal} = Billing.reverse_entry(other_purchase)
    assert {:ok, 1_100} = Billing.balance(wallet, authorize?: false)
  end
end
