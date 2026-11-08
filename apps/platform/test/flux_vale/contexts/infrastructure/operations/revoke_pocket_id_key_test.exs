defmodule FluxVale.Infrastructure.Operations.RevokePocketIdKeyTest do
  @moduledoc """
  The custody exit (#597 §4.3): owner-only, Secret deleted first (a
  404 tolerated — already gone IS revoked), row second, one :revoked
  event. Minted PocketID clients are untouched (S5's concern).
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Operations.InstanceK8s
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

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(Secret, :delete, fn _kc, _ns, _name -> :ok end)

    version = InstanceFixtures.app_version!()
    instance = InstanceFixtures.instance!(version, owner)

    PocketIdCustody.record!(
      %{
        organization_id: instance.organization_id,
        instance_id: instance.id,
        api_key_secret_ref: "fluxvale-pocketid-custody-#{instance.id}",
        verified_at: DateTime.utc_now()
      },
      authorize?: false
    )

    {:ok, org: org, owner: owner, instance: instance}
  end

  test "deletes the Secret, drops the row, audits the revoke", %{
    owner: owner,
    instance: instance
  } do
    expect(Secret, :delete, fn _kc, namespace, name ->
      assert namespace == InstanceK8s.gateway_access_namespace()
      assert name == "fluxvale-pocketid-custody-#{instance.id}"
      :ok
    end)

    assert :ok = Infrastructure.revoke_pocket_id_key(instance, actor: owner)

    assert {:error, _gone} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)

    assert {:ok, [%PocketIdCustodyEvent{kind: :revoked}]} =
             PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
  end

  # The recovery property's mirror: an out-of-band cleanup (or a retry
  # after a row-destroy failure) sees the Secret already gone — that
  # IS the revoked posture; the row delete proceeds.
  test "a Secret already gone (404) is tolerated, not an error", %{
    owner: owner,
    instance: instance
  } do
    stub(Secret, :delete, fn _kc, _ns, _name ->
      {:error, %FluxVale.Clients.K8s.Error{reason: :not_found}}
    end)

    assert :ok = Infrastructure.revoke_pocket_id_key(instance, actor: owner)
    assert {:error, _gone} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)
  end

  test "a Secret delete failure fails the revoke — the row survives for the retry", %{
    owner: owner,
    instance: instance
  } do
    stub(Secret, :delete, fn _kc, _ns, _name -> {:error, :cluster_oops} end)

    assert {:error, :cluster_oops} = Infrastructure.revoke_pocket_id_key(instance, actor: owner)

    assert {:ok, _row_still_there} =
             PocketIdCustody.get_by_instance(instance.id, authorize?: false)

    assert {:ok, []} = PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
  end

  test "nothing stored = nothing to revoke", %{owner: owner, instance: instance} do
    assert :ok = Infrastructure.revoke_pocket_id_key(instance, actor: owner)

    assert {:error, :no_custody} = Infrastructure.revoke_pocket_id_key(instance, actor: owner)
  end

  test "a member (not the owner) is refused before any cluster call", %{
    org: org,
    instance: instance
  } do
    member = AccountsFixtures.user!()

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    stub(Secret, :delete, fn _kc, _ns, _n -> flunk("the exit is the owner's too") end)

    assert {:error, :not_org_owner} =
             Infrastructure.revoke_pocket_id_key(instance, actor: member)
  end

  test "a stranger is Forbidden on the authorized read", %{instance: instance} do
    {_other_org, stranger} = BillingFixtures.grant_free_org!()

    assert {:error, _forbidden} =
             Infrastructure.revoke_pocket_id_key(instance, actor: stranger)
  end

  test "a nil actor is refused as not-an-owner even authorize?-free", %{
    instance: instance
  } do
    assert {:error, :not_org_owner} =
             Infrastructure.revoke_pocket_id_key(instance, authorize?: false)
  end

  # The recovery property's tail: a row-destroy failure AFTER the
  # Secret is gone surfaces — the retry's 404-tolerant delete converges.
  test "a row-destroy failure surfaces after the Secret is deleted", %{
    owner: owner,
    instance: instance
  } do
    stub(PocketIdCustody, :revoke, fn _custody, _opts -> {:error, :forced_db} end)

    assert {:error, :forced_db} =
             Infrastructure.revoke_pocket_id_key(instance, actor: owner)

    # The row survives for the retry; no :revoked event for what did
    # not finish.
    assert {:ok, _row} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)

    assert {:ok, []} = PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
  end
end
