defmodule FluxVale.Infrastructure.PocketIdWiringTest do
  @moduledoc """
  The wiring row's contract (#597 S4): one ACTIVE row per app instance
  — the identity's teeth; members read their org's wiring, strangers
  read nothing; the write funnels are system-only (the operation's
  member fence is the fence, not the resource's policies).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Infrastructure.PocketIdWiring
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

  defp record_wiring!(instance, attrs \\ %{}) do
    base = %{
      instance_id: instance.id,
      pocket_id_instance_id: Ash.UUID.generate(),
      pocket_id_client_id: "client-#{System.unique_integer()}",
      pocket_id_secret_id: "secret-#{System.unique_integer()}"
    }

    merged = Map.merge(base, Map.new(attrs))
    PocketIdWiring.record!(merged, authorize?: false)
  end

  describe "the identity — one active wiring per instance" do
    test "a second row for the same instance is refused", %{instance: instance} do
      record_wiring!(instance)

      assert {:error, %Ash.Error.Invalid{}} =
               PocketIdWiring.record(
                 %{
                   instance_id: instance.id,
                   pocket_id_instance_id: Ash.UUID.generate(),
                   pocket_id_client_id: "c2",
                   pocket_id_secret_id: "s2"
                 },
                 authorize?: false
               )
    end

    test "get_by_instance finds the one row", %{instance: instance} do
      wiring = record_wiring!(instance)

      assert {:ok, found} = PocketIdWiring.get_by_instance(instance.id, authorize?: false)
      assert found.id == wiring.id
      assert %DateTime{} = found.wired_at
    end
  end

  describe "policies" do
    test "a member of the org reads the wiring row", %{org: org, instance: instance} do
      wiring = record_wiring!(instance)

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:ok, found} = PocketIdWiring.get_by_instance(instance.id, actor: member)
      assert found.id == wiring.id
    end

    test "a stranger's read finds nothing — the membership filter reads as not-found", %{
      instance: instance
    } do
      record_wiring!(instance)
      {_other_org, stranger} = BillingFixtures.grant_free_org!()

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               PocketIdWiring.get_by_instance(instance.id, actor: stranger)
    end

    test "the write funnels are system-only — an actor call is Forbidden", %{instance: instance} do
      assert {:error, %Ash.Error.Forbidden{}} =
               PocketIdWiring.record(
                 %{
                   instance_id: instance.id,
                   pocket_id_instance_id: Ash.UUID.generate(),
                   pocket_id_client_id: "c",
                   pocket_id_secret_id: "s"
                 },
                 actor: AccountsFixtures.platform_admin!()
               )
    end
  end

  # The teardown story: the wiring dies with its subject app instance
  # (the custody cascade stance) — the PocketID-side client is S5's
  # best-effort cleanup (D6), and the row must be gone so nothing
  # renders a wiring for a deleted instance.
  test "destroying the app instance cascades the wiring row", %{instance: instance} do
    record_wiring!(instance)

    :ok = Ash.destroy(instance, authorize?: false)

    assert {:error, _none} = PocketIdWiring.get_by_instance(instance.id, authorize?: false)
  end
end
