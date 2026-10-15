defmodule FluxVale.Billing.TopupTest do
  @moduledoc """
  Topup resource contract (#136): member-scoped reads, system-only
  writes, one payment request per row.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  defp topup!(org) do
    {:ok, topup} =
      Topup.create(%{organization_id: org.id, amount_cents: 500}, authorize?: false)

    topup
  end

  test "members read their org's top-ups; strangers don't" do
    {org, _wallet} = BillingFixtures.funded_wallet!()
    topup = topup!(org)

    member =
      org
      |> Ash.load!([:members], authorize?: false)
      |> Map.get(:members)
      |> List.first()

    assert {:ok, row} = Topup.get_by_id(topup.id, actor: member)
    assert row.id == topup.id

    stranger = AccountsFixtures.user!()

    # A get? read hides existence from strangers (Ash surfaces policy
    # denials on fetches as NotFound) — the row must not leak.
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Topup.get_by_id(topup.id, actor: stranger)
  end

  test "actor-driven creation and transitions are forbidden" do
    {org, _wallet} = BillingFixtures.funded_wallet!()
    topup = topup!(org)

    member =
      org
      |> Ash.load!([:members], authorize?: false)
      |> Map.get(:members)
      |> List.first()

    assert {:error, %Ash.Error.Forbidden{}} =
             Topup.create(%{organization_id: org.id, amount_cents: 500}, actor: member)

    assert {:error, %Ash.Error.Forbidden{}} =
             Topup.mark_completed(topup, %{payment_id: "pay_1"}, actor: member)
  end

  test "a payment request names at most one top-up (unique_payment_request)" do
    {org, _wallet} = BillingFixtures.funded_wallet!()
    topup = topup!(org)

    {:ok, _attached} =
      Topup.attach_checkout(topup, %{payment_request_id: "pr_1"}, authorize?: false)

    other = topup!(org)

    assert {:error, %Ash.Error.Invalid{}} =
             Topup.attach_checkout(other, %{payment_request_id: "pr_1"}, authorize?: false)
  end
end
