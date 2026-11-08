defmodule FluxVale.Infrastructure.Operations.UsePocketIdKeyTest do
  @moduledoc """
  The audited key-use seam (#597 S2, the D1 amendment) — the ONE read
  path for the held key: reads the Secret, lands a :used event with
  the purpose and actor, returns the raw key to the internal caller.
  No user surface ever sees it (the read_api_credential stance).
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdCustodyEvent
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @key "test-key-not-a-real-credential"

  setup do
    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance create rides the funded-wallet gate (#124).
    BillingFixtures.funded_wallet!(org: org)

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    version = InstanceFixtures.app_version!()
    instance = InstanceFixtures.instance!(version, owner)

    custody =
      PocketIdCustody.record!(
        %{
          organization_id: instance.organization_id,
          instance_id: instance.id,
          api_key_secret_ref: "fluxvale-pocketid-custody-#{instance.id}",
          verified_at: DateTime.utc_now()
        },
        authorize?: false
      )

    {:ok, org: org, owner: owner, instance: instance, custody: custody}
  end

  test "reads the key from the Secret and audits the use", %{
    owner: owner,
    instance: instance,
    custody: custody
  } do
    expect(Secret, :get_data, fn _kc, namespace, ref ->
      assert namespace == InstanceK8s.gateway_access_namespace()
      assert ref == custody.api_key_secret_ref
      {:ok, %{"POCKETID_API_KEY" => @key}}
    end)

    assert {:ok, key} = Infrastructure.use_pocket_id_key(custody, "client_mint", actor: owner)
    assert key == @key

    assert {:ok, [%PocketIdCustodyEvent{kind: :used, purpose: "client_mint"}]} =
             PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
  end

  # The system path (S4's wiring inside a job): actor-less is honest —
  # the event records the platform, not a fabricated operator.
  test "a system use records a nil actor", %{custody: custody} do
    stub(Secret, :get_data, fn _kc, _ns, _ref -> {:ok, %{"POCKETID_API_KEY" => @key}} end)

    assert {:ok, _key} = Infrastructure.use_pocket_id_key(custody, "client_rotate")

    assert {:ok, [%PocketIdCustodyEvent{actor_id: nil}]} =
             PocketIdCustodyEvent.for_instance(custody.instance_id, authorize?: false)
  end

  test "a missing Secret (revoked out of band) is :no_api_key, unaudited", %{custody: custody} do
    stub(Secret, :get_data, fn _kc, _ns, _ref ->
      {:error, %Error{reason: :not_found}}
    end)

    assert {:error, :no_api_key} = Infrastructure.use_pocket_id_key(custody, "client_mint")

    assert {:ok, []} = PocketIdCustodyEvent.for_instance(custody.instance_id, authorize?: false)
  end

  test "a malformed Secret (out-of-band tampering) is its own verdict", %{custody: custody} do
    stub(Secret, :get_data, fn _kc, _ns, _ref -> {:ok, %{"SOMETHING_ELSE" => "x"}} end)

    assert {:error, :api_key_malformed} = Infrastructure.use_pocket_id_key(custody, "client_mint")
  end

  test "a cluster read failure surfaces", %{custody: custody} do
    stub(Secret, :get_data, fn _kc, _ns, _ref -> {:error, %Error{reason: :timeout}} end)

    assert {:error, %Error{reason: :timeout}} =
             Infrastructure.use_pocket_id_key(custody, "client_mint")
  end
end
