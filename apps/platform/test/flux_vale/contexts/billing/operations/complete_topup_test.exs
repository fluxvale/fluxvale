defmodule FluxVale.Billing.Operations.CompleteTopupTest do
  @moduledoc """
  CompleteTopup contract (#136): the one credit path — exactly once per
  payment (idempotency key), amounts cross-checked against the row,
  references never cross-wired.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures

  defp topup!(amount_cents, opts \\ []) do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(
        %{
          organization_id: org.id,
          amount_cents: amount_cents,
          buyer_email: "buyer@example.com",
          billing_country: Keyword.get(opts, :billing_country)
        },
        authorize?: false
      )

    if request_id = Keyword.get(opts, :payment_request_id) do
      {:ok, _attached} =
        Topup.attach_checkout(topup, %{payment_request_id: request_id}, authorize?: false)
    end

    topup
  end

  defp outcome(topup, overrides \\ []) do
    Map.merge(
      %{
        payment_request_id: topup.payment_request_id || "pr_1",
        payment_id: "pay_1",
        amount_cents: topup.amount_cents,
        idempotency_key: "hitpay:pay_1",
        topup_id: topup.id
      },
      Map.new(overrides)
    )
  end

  test "credits the wallet once and completes the row" do
    topup = topup!(500, payment_request_id: "pr_1")

    outcome = outcome(topup)
    assert {:ok, completed} = Billing.complete_topup(outcome)
    assert completed.status == :completed
    assert completed.payment_id == "pay_1"

    wallet = wallet_of(topup)
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
  end

  test "a replayed outcome credits nothing more" do
    topup = topup!(500, payment_request_id: "pr_1")

    outcome = outcome(topup)
    assert {:ok, _completed} = Billing.complete_topup(outcome)
    assert {:ok, :already_completed} = Billing.complete_topup(outcome)

    wallet = wallet_of(topup)
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
  end

  test "a matching payment_request_id resolves without topup_id" do
    topup = topup!(300, payment_request_id: "pr_9")

    bare = %{
      payment_request_id: "pr_9",
      payment_id: "pay_9",
      amount_cents: 300,
      idempotency_key: "hitpay:pay_9"
    }

    assert {:ok, completed} = Billing.complete_topup(bare)
    assert completed.id == topup.id
  end

  test "a stale topup_id falls back to the payment_request_id lookup" do
    topup = topup!(300, payment_request_id: "pr_9")

    outcome = outcome(topup, payment_request_id: "pr_9", topup_id: "a-gone-row")

    assert {:ok, completed} = Billing.complete_topup(outcome)
    assert completed.id == topup.id
  end

  test "the reference fallback completes an unattached row (attach-then-crash window)" do
    topup = topup!(500)

    outcome = outcome(topup, payment_request_id: "pr_healed")
    assert {:ok, completed} = Billing.complete_topup(outcome)

    assert completed.status == :completed
    assert completed.payment_request_id == "pr_healed"
    wallet = wallet_of(topup)
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
  end

  test "a reference naming another request's row never credits" do
    topup = topup!(500, payment_request_id: "pr_mine")

    outcome = outcome(topup, payment_request_id: "pr_theirs")
    assert {:error, :request_mismatch} = Billing.complete_topup(outcome)
    wallet = wallet_of(topup)
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "an amount mismatch never credits" do
    topup = topup!(500, payment_request_id: "pr_1")

    outcome = outcome(topup, amount_cents: 9_999)
    assert {:error, :amount_mismatch} = Billing.complete_topup(outcome)

    # The row stays pending — an operator reconciles it by hand.
    reloaded = Topup.get_by_id!(topup.id, authorize?: false)
    assert reloaded.status == :pending
    wallet = wallet_of(topup)
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "a failed top-up never credits, even on a completed outcome" do
    topup = topup!(500, payment_request_id: "pr_1")
    {:ok, failed} = Topup.mark_failed(topup, %{}, authorize?: false)

    outcome = outcome(failed)
    assert {:error, :topup_failed} = Billing.complete_topup(outcome)
    wallet = wallet_of(topup)
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "an unknown payment request answers :unknown_topup" do
    assert {:error, :unknown_topup} =
             Billing.complete_topup(%{
               payment_request_id: "pr_nope",
               payment_id: "pay_nope",
               amount_cents: 500,
               idempotency_key: "hitpay:pay_nope"
             })
  end

  # Defensive: the billing surface provisions the wallet on mount, so a
  # top-up without one is an org built outside that flow. The credit
  # must fail closed — no wallet, no post — and the row stays pending.
  test "a missing wallet fails closed without completing the row" do
    org =
      Organization.create!(
        %{name: "walletless", slug: "wl-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    {:ok, topup} = Topup.create(%{organization_id: org.id, amount_cents: 500}, authorize?: false)

    outcome = outcome(topup, payment_request_id: "pr_1")

    assert {:error, _reason} = Billing.complete_topup(outcome)

    reloaded = Topup.get_by_id!(topup.id, authorize?: false)
    assert reloaded.status == :pending
  end

  defp wallet_of(topup) do
    topup = Topup.get_by_id!(topup.id, authorize?: false)
    org = Organization.get_by_id!(topup.organization_id, authorize?: false)
    {:ok, wallet} = Billing.ensure_wallet(org)
    wallet
  end
end
