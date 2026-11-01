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

  require Ash.Query

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

  test "platform admins read any wallet (support surface, #140)" do
    # A wallet the admin has no membership in — the goodwill flow's
    # wallet discovery in AshAdmin rides this read.
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 700)

    assert {:ok, 700} = Billing.balance(wallet, actor: admin())
  end

  # The waiver flip (paywall waiver): the one actor-facing update, the
  # /admin edit form's checkbox (`admin do update_actions([:set_waiver])`).
  # The waiver is NOT money — the ledger-inertness pin lives here, the
  # gate-OR pins live in ActorOrgHasPaidTest and the gateway suite.
  describe "set_waiver (the /admin flip)" do
    test "a platform admin flips the waiver on and off" do
      {_org, wallet} = BillingFixtures.funded_wallet!()

      assert {:ok, waived} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin())
      assert waived.paywall_waived == true

      assert {:ok, unwaived} = Wallet.set_waiver(waived, %{paywall_waived: false}, actor: admin())
      assert unwaived.paywall_waived == false
    end

    test "the flip is ledger-inert — balance and entry count unchanged both ways" do
      {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 700)
      admin = admin()

      {:ok, balance_before} = Billing.balance(wallet, authorize?: false)
      entries_before = count_entries(wallet)

      # Chained records — the un-flip edits the row as it now is.
      assert {:ok, waived} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin)
      assert {:ok, _unwaived} = Wallet.set_waiver(waived, %{paywall_waived: false}, actor: admin)

      assert {:ok, ^balance_before} = Billing.balance(wallet, authorize?: false)
      assert count_entries(wallet) == entries_before
    end

    test "the org's owner cannot flip the waiver — non-admins match no policy" do
      {_org, wallet} = BillingFixtures.funded_wallet!()

      owner =
        wallet
        |> Ash.load!([organization: [:members]], authorize?: false)
        |> Map.get(:organization)
        |> Map.get(:members)
        |> List.first()

      assert {:error, %Ash.Error.Forbidden{}} =
               Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: owner)
    end

    test "a generic update carrying paywall_waived stays forbidden (the old forbid holds)" do
      {_org, wallet} = BillingFixtures.funded_wallet!()

      member =
        wallet
        |> Ash.load!([organization: [:members]], authorize?: false)
        |> Map.get(:organization)
        |> Map.get(:members)
        |> List.first()

      assert {:error, %Ash.Error.Forbidden{}} =
               wallet
               |> Ash.Changeset.for_update(:set_carryover, %{})
               |> Ash.Changeset.force_change_attribute(:paywall_waived, true)
               |> Ash.update(actor: member)
    end

    test "the system writes stay forbidden — admins included" do
      {_org, wallet} = BillingFixtures.funded_wallet!()
      admin = admin()

      assert {:error, %Ash.Error.Forbidden{}} =
               wallet
               |> Ash.Changeset.for_update(:set_carryover, %{})
               |> Ash.Changeset.force_change_attribute(:carryover, 1)
               |> Ash.update(actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               wallet
               |> Ash.Changeset.for_update(:set_ladder_state, %{
                 negative_since: DateTime.utc_now()
               })
               |> Ash.update(actor: admin)
    end

    defp count_entries(wallet) do
      FluxVale.Billing.LedgerEntry
      |> Ash.Query.filter(wallet_id == ^wallet.id)
      |> Ash.count!(authorize?: false)
    end
  end

  # Bootstrap posture (mirrors the Ops policy tests): the precondition
  # runs authorize?: false; the policy itself is under test above.
  defp admin, do: AccountsFixtures.platform_admin!()
end
