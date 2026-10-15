defmodule FluxVale.Billing.Operations.FailTopupTest do
  @moduledoc """
  FailTopup contract (#136): pending → failed, terminal stays put,
  unknown ids answer :unknown_topup.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures

  defp topup!(payment_request_id, status \\ :pending) do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(%{organization_id: org.id, amount_cents: 500}, authorize?: false)

    {:ok, attached} =
      Topup.attach_checkout(topup, %{payment_request_id: payment_request_id}, authorize?: false)

    case status do
      :pending -> attached
      :failed -> elem(Topup.mark_failed(attached, %{}, authorize?: false), 1)
    end
  end

  test "a failed payment request marks the pending row failed" do
    topup!("pr_1")
    assert {:ok, %Topup{status: :failed}} = Billing.fail_topup("pr_1")
  end

  test "terminal rows stay put" do
    topup!("pr_1", :failed)
    assert {:ok, :already_terminal} = Billing.fail_topup("pr_1")
  end

  test "an unknown payment request answers :unknown_topup" do
    assert {:error, :unknown_topup} = Billing.fail_topup("pr_nope")
  end

  # Terminal-once: an out-of-order failed delivery landing after the
  # completed one must not flip the row — the credit stands.
  test "a late failed delivery cannot flip a completed row" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(%{organization_id: org.id, amount_cents: 500}, authorize?: false)

    {:ok, attached} =
      Topup.attach_checkout(topup, %{payment_request_id: "pr_1"}, authorize?: false)

    outcome = %{
      payment_request_id: "pr_1",
      payment_id: "pay_1",
      amount_cents: 500,
      idempotency_key: "hitpay:pay_1"
    }

    assert {:ok, _completed} = Billing.complete_topup(outcome)
    assert {:ok, :already_terminal} = Billing.fail_topup("pr_1")

    reloaded = Topup.get_by_id!(attached.id, authorize?: false)
    assert reloaded.status == :completed
  end
end
