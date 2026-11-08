defmodule FluxVale.Infrastructure.PocketIdCustodyTest do
  @moduledoc """
  The custody row's contract (#597 S2): one per (org, instance) — the
  identity's teeth; members read their org's custody, strangers read
  nothing; the write funnels are system-only (the operations' owner
  gate is the fence, not the resource's policies).

  Preconditions go through the actions (repo convention). The
  Instance itself needs a funded wallet + a cluster row — the
  fixtures own those.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdCustodyEvent
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance create rides the funded-wallet gate (#124).
    BillingFixtures.funded_wallet!(org: org)
    version = InstanceFixtures.app_version!()
    instance = InstanceFixtures.instance!(version, owner)

    {:ok, org: org, owner: owner, instance: instance}
  end

  defp record_custody!(instance) do
    PocketIdCustody.record!(
      %{
        organization_id: instance.organization_id,
        instance_id: instance.id,
        api_key_secret_ref: "fluxvale-pocketid-custody-#{instance.id}",
        verified_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  describe "the identity — one custody per (organization, instance)" do
    test "a second row for the same instance is refused", %{instance: instance} do
      record_custody!(instance)

      assert {:error, %Ash.Error.Invalid{}} =
               PocketIdCustody.record(
                 %{
                   organization_id: instance.organization_id,
                   instance_id: instance.id,
                   api_key_secret_ref: "fluxvale-pocketid-custody-#{instance.id}-2",
                   verified_at: DateTime.utc_now()
                 },
                 authorize?: false
               )
    end

    test "get_by_instance finds the one row", %{instance: instance} do
      custody = record_custody!(instance)

      assert {:ok, found} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)
      assert found.id == custody.id
    end
  end

  describe "policies" do
    test "a member of the org reads the custody row", %{org: org, instance: instance} do
      custody = record_custody!(instance)

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:ok, found} = PocketIdCustody.get_by_instance(instance.id, actor: member)
      assert found.id == custody.id
    end

    test "a stranger's read finds nothing — the membership filter reads as not-found", %{
      instance: instance
    } do
      record_custody!(instance)
      {_other_org, stranger} = BillingFixtures.grant_free_org!()

      # The get? read with a policy filter: a stranger sees the same
      # surface as an unknown id (the Instance page's own stance).
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               PocketIdCustody.get_by_instance(instance.id, actor: stranger)
    end

    # The event trail rides the same member gate: attributable in the
    # ORG's audit surface, closed to strangers.
    test "a member reads the custody events; a stranger cannot", %{
      org: org,
      instance: instance
    } do
      PocketIdCustodyEvent.record!(
        %{organization_id: org.id, instance_id: instance.id, kind: :stored},
        authorize?: false
      )

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:ok, [%PocketIdCustodyEvent{kind: :stored}]} =
               PocketIdCustodyEvent.for_instance(instance.id, actor: member)

      {_other_org, stranger} = BillingFixtures.grant_free_org!()

      # A stranger's list read is the filtered empty list (the policy
      # scopes rows, list reads never raise on it).
      assert {:ok, []} = PocketIdCustodyEvent.for_instance(instance.id, actor: stranger)
    end

    test "the write funnels are system-only — an owner actor is still Forbidden", %{
      org: org,
      owner: owner,
      instance: instance
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               PocketIdCustody.record(
                 %{
                   organization_id: org.id,
                   instance_id: instance.id,
                   api_key_secret_ref: "x",
                   verified_at: DateTime.utc_now()
                 },
                 actor: owner
               )

      custody = record_custody!(instance)

      assert {:error, %Ash.Error.Forbidden{}} =
               PocketIdCustody.record_replacement(
                 custody,
                 %{api_key_secret_ref: "y", verified_at: DateTime.utc_now()},
                 actor: owner
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               PocketIdCustody.revoke(custody, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               PocketIdCustodyEvent.record(
                 %{organization_id: org.id, instance_id: instance.id, kind: :used},
                 actor: owner
               )
    end
  end

  describe "for_organization — the detection read (#597 S3's seam)" do
    test "lists the org's custody rows only", %{org: org, owner: owner, instance: instance} do
      record_custody!(instance)

      # A second org's custody must not leak in (funded: its instance
      # create rides the same wallet gate).
      {other_org, other_owner} = BillingFixtures.grant_free_org!()
      BillingFixtures.funded_wallet!(org: other_org)
      other_version = InstanceFixtures.app_version!()
      other_instance = InstanceFixtures.instance!(other_version, other_owner)

      PocketIdCustody.record!(
        %{
          organization_id: other_instance.organization_id,
          instance_id: other_instance.id,
          api_key_secret_ref: "other",
          verified_at: DateTime.utc_now()
        },
        authorize?: false
      )

      assert {:ok, [only]} = PocketIdCustody.for_organization(org.id, actor: owner)
      assert only.instance_id == instance.id
    end
  end

  # The FK's teeth: teardown hard-deletes the instance row — a
  # restrict here would wedge teardown into an Oban retry loop
  # whenever a PocketID is destroyed while custody exists. Custody and
  # its audit trail die with their subject (the snapshot stance); the
  # access-namespace Secret is S5's best-effort cleanup.
  describe "the instance cascade" do
    test "destroying the PocketID takes the custody row and its events along", %{
      owner: owner,
      instance: instance
    } do
      record_custody!(instance)

      PocketIdCustodyEvent.record!(
        %{organization_id: instance.organization_id, instance_id: instance.id, kind: :stored},
        authorize?: false
      )

      assert :ok = Ash.destroy(instance, actor: owner)

      assert {:error, _gone} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)
      assert {:ok, []} = PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
    end
  end
end
