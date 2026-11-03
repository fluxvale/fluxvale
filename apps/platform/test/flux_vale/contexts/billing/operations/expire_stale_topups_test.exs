defmodule FluxVale.Billing.Operations.ExpireStaleTopupsTest do
  @moduledoc """
  ExpireStaleTopups contract (#364): a pending row past the TTL flips
  to `:expired`, fresh and terminal rows stay put, the pass is
  idempotent. The money answer — a completion landing after expiry
  still credits — is CompleteTopup's suite.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures

  defp topup!(payment_request_id) do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(%{organization_id: org.id, amount_cents: 500}, authorize?: false)

    {:ok, attached} =
      Topup.attach_checkout(topup, %{payment_request_id: payment_request_id}, authorize?: false)

    attached
  end

  # A pending row older than the TTL is a state no action can produce
  # (created_at is a write-time stamp) — the sanctioned Ash.seed! case,
  # the org-members backdate precedent.
  defp aged_pending_topup!(payment_request_id, age_hours) do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    Ash.Seed.seed!(Topup, %{
      organization_id: org.id,
      amount_cents: 500,
      payment_request_id: payment_request_id,
      created_at: DateTime.add(DateTime.utc_now(), -age_hours * 3600, :second),
      updated_at: DateTime.utc_now()
    })
  end

  test "a pending row past the TTL flips to :expired" do
    aged_pending_topup!("pr_old", 25)

    assert {:ok, [expired]} = Billing.expire_stale_topups()
    assert expired.status == :expired

    reloaded = Topup.get_by_id!(expired.id, authorize?: false)
    assert reloaded.status == :expired
  end

  test "a fresh pending row stays put" do
    topup!("pr_new")

    assert {:ok, []} = Billing.expire_stale_topups()
  end

  test "the pass is idempotent — an :expired row isn't re-listed" do
    aged_pending_topup!("pr_old", 25)

    assert {:ok, [_expired]} = Billing.expire_stale_topups()
    assert {:ok, []} = Billing.expire_stale_topups()
  end

  test "terminal rows never flip — a completed row stays completed" do
    topup = topup!("pr_done")

    {:ok, _completed} =
      Billing.complete_topup(%{
        payment_request_id: "pr_done",
        payment_id: "pay_1",
        amount_cents: 500,
        idempotency_key: "hitpay:pay_1"
      })

    assert {:ok, []} = Billing.expire_stale_topups()

    reloaded = Topup.get_by_id!(topup.id, authorize?: false)
    assert reloaded.status == :completed
  end

  test "terminal rows never flip — a failed row stays failed" do
    topup = topup!("pr_dead")
    {:ok, _failed} = Topup.mark_failed(topup, %{}, authorize?: false)

    assert {:ok, []} = Billing.expire_stale_topups()

    reloaded = Topup.get_by_id!(topup.id, authorize?: false)
    assert reloaded.status == :failed
  end
end
