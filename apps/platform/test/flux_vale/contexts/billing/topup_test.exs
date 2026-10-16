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

  test "create accepts the checkout tax layer's fields with the settled defaults" do
    {org, _wallet} = BillingFixtures.funded_wallet!()

    assert {:ok, topup} =
             Topup.create(
               %{
                 organization_id: org.id,
                 amount_cents: 500,
                 tax_cents: 95,
                 billing_country: "DE",
                 billing_state: nil,
                 customer_type: :business,
                 vat_number: "DE123456789",
                 ip_country: "DE",
                 reverse_charge?: true,
                 ip_matches_billing?: true,
                 tax_rate_bp: 1900
               },
               authorize?: false
             )

    assert topup.tax_cents == 95
    assert topup.billing_country == "DE"
    assert topup.customer_type == :business
    assert topup.vat_number == "DE123456789"
    assert topup.ip_country == "DE"
    assert topup.reverse_charge? == true
    assert topup.ip_matches_billing? == true
    assert topup.tax_rate_bp == 1900

    # Defaults for a bare create — a top-up is 0% VAT and consumer
    # unless the checkout says otherwise.
    bare = topup!(org)
    assert bare.tax_cents == 0
    assert bare.customer_type == :consumer
    assert bare.reverse_charge? == false
    assert bare.ip_matches_billing? == false
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
