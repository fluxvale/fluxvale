defmodule FluxVale.Billing.WalletTest do
  @moduledoc """
  Wallet resource contract (#120): one per org, live-sum balance, system-
  only writes, member-scoped reads.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  test "an org has exactly one wallet (unique_org)" do
    {org, wallet} = BillingFixtures.funded_wallet!()

    assert {:error, %Ash.Error.Invalid{}} =
             Wallet.create(%{organization_id: org.id}, authorize?: false)

    {:ok, same} = Wallet.get_by_organization(org.id, authorize?: false)
    assert same.id == wallet.id
  end

  test "balance is the live ledger sum — zero for an unfunded wallet" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "balance tracks posted entries" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 2_500)

    assert {:ok, 2_500} = Billing.balance(wallet, authorize?: false)
  end

  test "actor-driven creation and carryover writes are forbidden" do
    {org, wallet} = BillingFixtures.funded_wallet!()
    member = AccountsFixtures.user!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Wallet.create(%{organization_id: org.id}, actor: member)

    assert {:error, %Ash.Error.Forbidden{}} =
             wallet
             |> Ash.Changeset.for_update(:set_carryover, %{})
             |> Ash.Changeset.force_change_attribute(:carryover, 1)
             |> Ash.update(actor: member)
  end

  test "members read their org's wallet; strangers don't" do
    {_org, wallet} = BillingFixtures.funded_wallet!()

    member =
      wallet
      |> Ash.load!([organization: [:members]], authorize?: false)
      |> Map.get(:organization)
      |> Map.get(:members)
      |> List.first()

    assert {:ok, _balance} = Billing.balance(wallet, actor: member)

    stranger = AccountsFixtures.user!()

    # read policies filter to nothing — the wrapped NotFound shape
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Billing.balance(wallet, actor: stranger)
  end
end
