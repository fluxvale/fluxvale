defmodule FluxVale.AdminAuthorityPolicyTest do
  @moduledoc """
  The blanket authority's policy proofs (#644, ADR-0047): a platform
  admin reads and writes across orgs through the bypass — including
  system-only gates the doctrine deliberately admits (D4) — while
  members, strangers, and PAT-context calls are unchanged. The
  existing per-resource suites are the wider regression net; this file
  pins the doctrine's own seams, one arm per family.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Accounts.Organization
  alias FluxVale.Api.Scopes
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Topup
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.CallOutsideMachineApi
  alias FluxVale.Feedback.Post
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.FeedbackFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  # The doctrine's actor: a platform admin who is a member of exactly
  # their own JIT-provisioned org — nothing else.
  defp admin, do: AccountsFixtures.platform_admin!()

  # A foreign org (the admin is not a member): funded wallet, owner
  # member, one ledger row from the funding grant.
  defp foreign_org! do
    {org, wallet} = BillingFixtures.funded_wallet!()

    owner =
      org
      |> Ash.load!(:members, authorize?: false)
      |> Map.get(:members)
      |> List.first()

    {org, wallet, owner}
  end

  defp foreign_instance!(owner) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    InstanceFixtures.instance!(version, owner)
  end

  # The PAT-context marker the /api/v1 boundary bridges into the Ash
  # request context — the bypass's refusal condition (policy-level pin;
  # the boundary pin lives in the route suite).
  defp pat_context do
    %{Scopes.pat_scopes_context_key() => ["instances:read"]}
  end

  describe "reads cross-org — the bypass widens every family" do
    test "instance: an admin reads an org they do not belong to", %{test: test} do
      admin = admin()
      {_org, _wallet, owner} = foreign_org!()
      instance = foreign_instance!(owner)

      assert {:ok, read} = Instance.get_by_id(instance.id, actor: admin, authorize?: true)
      assert read.id == instance.id

      # The member's own read is untouched — same call, own org.
      assert {:ok, _own} = Instance.get_by_id(instance.id, actor: owner, authorize?: true)

      # A stranger is still refused: the bypass condition never fires
      # for a non-admin, the member filter applies verbatim.
      stranger = AccountsFixtures.user!()
      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, actor: stranger)
    end

    test "organization: the admin's read is unfiltered; the member's stays scoped", %{test: test} do
      admin = admin()
      {org, _wallet, owner} = foreign_org!()
      other_user = AccountsFixtures.user!()
      other = AccountsFixtures.owned_org!(other_user)

      admin_rows = Ash.read!(Organization, actor: admin, authorize?: true)
      owner_rows = Ash.read!(Organization, actor: owner, authorize?: true)

      # The admin sees orgs they do not belong to (the doctrine); the
      # member's read stays member-scoped — neither fixture org leaks.
      assert Enum.any?(admin_rows, &(&1.id == org.id))
      assert Enum.any?(admin_rows, &(&1.id == other.id))
      assert Enum.all?(owner_rows, fn row -> row.id == org.id end)
    end

    test "membership and invite rows: the admin reads another org's roster", %{} do
      admin = admin()
      {org, _wallet, owner} = foreign_org!()

      {:ok, _invite} =
        MembershipInvite
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(
          :token_hash,
          MembershipInvite.token_hash("admin-authority-#{System.unique_integer()}")
        )
        |> Ash.Changeset.for_create(
          :create,
          %{organization_id: org.id, email: "invitee@fluxvale.test"},
          authorize?: false
        )
        |> Ash.create()

      memberships =
        Membership
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(actor: admin, authorize?: true)

      invites =
        MembershipInvite
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(actor: admin, authorize?: true)

      assert Enum.any?(memberships, &(&1.user_id == owner.id))
      assert length(invites) == 1

      # A stranger sees neither — the member filter applies verbatim.
      stranger = AccountsFixtures.user!()

      stranger_rows =
        Membership
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(actor: stranger, authorize?: true)

      assert stranger_rows == []
    end

    test "wallet and ledger: the admin's read rides the #140 arm, unchanged", %{} do
      admin = admin()
      {_org, wallet, _owner} = foreign_org!()

      assert {:ok, read} =
               Wallet.get_by_organization(wallet.organization_id,
                 actor: admin,
                 authorize?: true
               )

      assert read.id == wallet.id

      assert {:ok, entries} =
               LedgerEntry
               |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet.id},
                 actor: admin,
                 authorize?: true
               )
               |> Ash.read()

      assert entries != []
    end

    test "topup: refused yesterday, admitted through the bypass today", %{} do
      admin = admin()
      {org, _wallet, owner} = foreign_org!()

      {:ok, topup} =
        Topup.create(
          %{
            organization_id: org.id,
            amount_cents: 5_000,
            tax_cents: 0,
            buyer_email: "buyer@fluxvale.test"
          },
          authorize?: false
        )

      assert {:ok, read} = Topup.get_by_id(topup.id, actor: admin, authorize?: true)
      assert read.id == topup.id

      # Strangers keep today's shape: the read policy is member-scoped
      # with no admin arm, and the bypass never fires for non-admins.
      stranger = AccountsFixtures.user!()
      assert {:error, %Ash.Error.Invalid{}} = Topup.get_by_id(topup.id, actor: stranger)
    end

    test "feedback: a post of another org reads through the admin", %{} do
      admin = admin()
      post = FeedbackFixtures.post!()

      assert {:ok, _row} =
               Post
               |> Ash.Query.filter(id == ^post.id)
               |> Ash.read_one(actor: admin, authorize?: true)
    end
  end

  describe "writes cross-org — paths that refused the admin yesterday" do
    test "topup create: the system-only gate admits the admin (D4)", %{} do
      admin = admin()
      {org, _wallet, owner} = foreign_org!()

      attrs = %{
        organization_id: org.id,
        amount_cents: 5_000,
        tax_cents: 0,
        buyer_email: "buyer@fluxvale.test"
      }

      # Yesterday: forbid_if(always()) refused every actor. Today the
      # bypass admits the platform admin; members stay refused.
      assert {:ok, %Topup{}} = Topup.create(attrs, actor: admin, authorize?: true)
      assert {:error, %Ash.Error.Forbidden{}} = Topup.create(attrs, actor: owner)
    end

    test "ledger create: the posting machinery admits the admin (D4)", %{} do
      admin = admin()
      {_org, wallet, _owner} = foreign_org!()

      attrs = %{
        wallet_id: wallet.id,
        amount: 100,
        type: :credit,
        reason: :adjustment,
        idempotency_key: "admin-authority-#{System.unique_integer()}"
      }

      assert {:ok, %LedgerEntry{}, _notifications} =
               LedgerEntry
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(actor: admin, authorize?: true, return_notifications?: true)
    end

    test "instance create: the membership fence no longer stops the admin", %{} do
      admin = admin()
      {org, _wallet, _owner} = foreign_org!()
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      # Yesterday: a non-member naming a funded org was Forbidden
      # (#408's fence). Today the bypass carries the admin in.
      assert {:ok, %Instance{}} =
               Instance.create(
                 %{
                   name: "Admin Authority",
                   app_version_id: version.id,
                   organization_id: org.id
                 },
                 actor: admin,
                 authorize?: true
               )
    end

    test "set_waiver on another org's wallet rides its #140 arm, unchanged", %{} do
      admin = admin()
      {_org, wallet, _owner} = foreign_org!()

      assert {:ok, %Wallet{paywall_waived: true}} =
               wallet
               |> Ash.Changeset.for_update(:set_waiver, %{paywall_waived: true})
               |> Ash.update(actor: admin, authorize?: true)
    end
  end

  describe "the PAT refusal at policy level (the boundary pin rides the route suite)" do
    test "the request-context marker switches the bypass off", %{} do
      admin = admin()
      {_org, _wallet, owner} = foreign_org!()
      instance = foreign_instance!(owner)

      query =
        Instance
        |> Ash.Query.for_read(:get_by_id, %{id: instance.id},
          actor: admin,
          authorize?: true,
          context: pat_context()
        )
        |> Ash.Query.filter(id == ^instance.id)

      # The bypass condition fails; the member filter below applies
      # verbatim — the admin's PAT keeps today's member-shaped answer.
      assert {:ok, nil} = Ash.read_one(query)
    end

    test "the process mark (the MCP boundary's rung) switches it off too", %{} do
      admin = admin()
      {_org, _wallet, owner} = foreign_org!()
      instance = foreign_instance!(owner)

      key = CallOutsideMachineApi.machine_api_mark_key()
      Process.put(key, true)

      assert {:error, %Ash.Error.Invalid{}} =
               Instance.get_by_id(instance.id, actor: admin, authorize?: true)
    after
      Process.delete(CallOutsideMachineApi.machine_api_mark_key())
    end

    test "armed resources keep the admin's PAT behavior byte-for-byte", %{} do
      admin = admin()
      {_org, wallet, _owner} = foreign_org!()

      # The #140 read arm is a pure actor check — no PAT refusal rides
      # it, so an admin's token reads any wallet exactly as today.
      query =
        Ash.Query.for_read(
          Wallet,
          :get_by_organization,
          %{
            organization_id: wallet.organization_id
          },
          actor: admin,
          authorize?: true,
          context: pat_context()
        )

      assert {:ok, [_row]} = Ash.read(query)
    end
  end

  describe "the check's own shapes" do
    test "a subject carrying no context map answers outside — session-shaped callers", %{} do
      # The catch-all arm: nothing bridged a request context in, and no
      # process mark exists — the honest non-PAT answer.
      assert CallOutsideMachineApi.match?(admin(), %{subject: %{}}, [])
    end

    test "describe names the call property, not an actor shape" do
      assert CallOutsideMachineApi.describe([]) == "call originates outside the machine API"
    end
  end
end
