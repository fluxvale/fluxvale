defmodule FluxVale.Infrastructure.Operations.GatewayPolicySurvivalTest do
  @moduledoc false

  # The P1 from #272's hostile review: the namespace NetworkPolicy has TWO
  # independent dimensions — the exposure floor (edge vs. no edge) and the
  # access layer's gateway peer. The exposure writers used to rebuild the
  # object from `network_policy_spec(:public | :private)`, a spec that
  # knew nothing about gateways, so an ordinary exposure flip or a
  # redeploy silently deleted the gateway peer: the AccessRoute row
  # survived, the gateway kept billing, and the instance was permanently
  # unreachable with nothing to heal it.
  #
  # Both writers are pinned here because both had the bug — special-casing
  # the toggle alone would leave the redeploy path broken.

  # NOT async: the fail-loud arm below deletes the :namespace key from
  # global app env (restored in on_exit) — concurrent provider tests
  # call the raising resolver and die on the window.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.DeployInstance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    InstanceFixtures.local_cluster!()
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    # The provider is stubbed: these tests are about the POLICY the two
    # exposure writers build, not the cluster work attach/detach do.
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :attach_instance, fn _gateway, _instance -> {:ok, %{}} end)
    stub(Tailscale, :detach_instance, fn _gateway, _instance -> :ok end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  describe "the spec itself" do
    test "an attached private instance admits its gateway, pod-narrowed", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = attached_instance!(org, owner, gateway, :private)

      spec = InstanceK8s.network_policy_spec(instance)

      # Private: no edge entry. The gateway entry is the whole point.
      assert [peer] = spec.ingress_from_sources
      assert peer.namespace == access_namespace()
      assert peer.match_labels == InstanceK8s.gateway_pod_labels(gateway.id)
    end

    test "an attached PUBLIC instance keeps the edge whole-namespace", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = attached_instance!(org, owner, gateway, :public)

      spec = InstanceK8s.network_policy_spec(instance)

      # Two dimensions, two shapes: Traefik's pods are not ours to label,
      # so the edge entry stays whole-namespace while the gateway entry is
      # narrowed. Collapsing both to one selector would break public
      # traffic on every attached instance.
      namespaces = Enum.map(spec.ingress_from_sources, & &1.namespace)
      edge = Application.fetch_env!(:flux_vale, :instance_ingress_namespace)

      assert edge in namespaces
      assert access_namespace() in namespaces

      edge_peer = Enum.find(spec.ingress_from_sources, &(&1.namespace == edge))
      refute Map.has_key?(edge_peer, :match_labels)
    end

    test "an attached instance with no access namespace configured FAILS LOUDLY", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = attached_instance!(org, owner, gateway, :private)

      # Carried finding #1 chose fail-loud over degradation: at base,
      # attach admitted the peer into the provider's "fluxvale-access"
      # fallback while the instance-side spec builder dropped the peer
      # on the next exposure flip or redeploy, silently severing
      # reachability. The old contract here — degrade to the plain
      # floor — is exactly the silent half-deploy the fix removes, so
      # this now raises.
      put_access_config(:delete, :namespace)

      assert_raise KeyError, ~r/key :namespace not found/, fn ->
        InstanceK8s.network_policy_spec(instance)
      end
    end

    test "an unattached instance keeps the plain exposure floor", %{org: _org, owner: owner} do
      instance = unattached_instance!(owner, :private)

      # The pre-#268 shape, unchanged for every instance that never opts in.
      assert InstanceK8s.network_policy_spec(instance) == %{ingress_from_namespaces: []}
    end
  end

  describe "the toggle path (SetExposure)" do
    test "going private PRESERVES the gateway peer", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = attached_instance!(org, owner, gateway, :public)
      ns = instance.namespace

      stub_route_deletes()
      expect_policy(ns, gateway, :private)

      assert {:ok, private} = Instance.set_exposure(instance, %{exposure: :private}, actor: owner)
      assert private.exposure == :private
    end

    test "going public PRESERVES the gateway peer and re-admits the edge", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = attached_instance!(org, owner, gateway, :private)
      ns = instance.namespace

      stub_route_creates()
      edge = Application.fetch_env!(:flux_vale, :instance_ingress_namespace)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
        namespaces = Enum.map(spec.ingress_from_sources, & &1.namespace)
        assert edge in namespaces
        assert access_namespace() in namespaces

        gateway_peer = Enum.find(spec.ingress_from_sources, &(&1.namespace == access_namespace()))
        assert gateway_peer.match_labels == InstanceK8s.gateway_pod_labels(gateway.id)
        {:ok, %{}}
      end)

      assert {:ok, public} = Instance.set_exposure(instance, %{exposure: :public}, actor: owner)
      assert public.exposure == :public
    end
  end

  describe "the redeploy path (DeployInstance)" do
    test "a redeploy of an attached private instance PRESERVES the gateway peer", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = attached_instance!(org, owner, gateway, :private)
      ns = instance.namespace

      stub_deploy_operands()
      expect_policy(ns, gateway, :private)

      # The deploy trigger's subject.
      deploying =
        InstanceFixtures.pin!(instance, status: :deploying, deployed_at: DateTime.utc_now())

      assert {:ok, _deployed} = DeployInstance.call(deploying)
    end
  end

  # --- helpers -------------------------------------------------------

  defp put_access_config(action, key) do
    previous = Application.get_env(:flux_vale, :access_gateway)

    put = fn config ->
      Application.put_env(:flux_vale, :access_gateway, config)
    end

    updated =
      case action do
        :delete -> Keyword.delete(previous, key)
        _put -> Keyword.put(previous, key, "some-value")
      end

    put.(updated)
    on_exit(fn -> put.(previous) end)
  end

  defp access_namespace, do: Application.get_env(:flux_vale, :access_gateway)[:namespace]

  # An instance with a real AccessRoute row — the durable record both
  # writers must read. The provider's cluster work is stubbed, so the row
  # is created through the resource directly (the same row attach writes).
  defp attached_instance!(org, owner, gateway, exposure) do
    instance = unattached_instance!(owner, exposure)

    {:ok, _route} =
      AccessRoute.create(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: route_key(instance)},
        authorize?: false
      )

    instance
  end

  defp route_key(instance), do: "84#{String.slice(to_string(instance.id), -2, 2)}"

  defp unattached_instance!(owner, exposure) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(%{name: "App #{System.unique_integer()}", app_version_id: version.id},
        actor: owner
      )

    instance
    |> InstanceFixtures.pin!(
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now(),
      exposure: exposure
    )
    |> InstanceFixtures.walk_to!(:running)
  end

  defp expect_policy(ns, gateway, exposure) do
    expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
      gateway_peer =
        Enum.find(spec.ingress_from_sources || [], &(&1.namespace == access_namespace()))

      assert gateway_peer, "the gateway peer was dropped from the policy"
      assert gateway_peer.match_labels == InstanceK8s.gateway_pod_labels(gateway.id)

      case exposure do
        :private ->
          refute Enum.any?(spec.ingress_from_sources, &(&1.namespace == edge_namespace()))

        :public ->
          assert Enum.any?(spec.ingress_from_sources, &(&1.namespace == edge_namespace()))
      end

      {:ok, %{}}
    end)
  end

  defp edge_namespace, do: Application.fetch_env!(:flux_vale, :instance_ingress_namespace)

  defp stub_route_deletes do
    stub(Ingress, :delete, fn _kc, _ns, _name -> :ok end)
    reject(Ingress, :create, 4)
    reject(Middleware, :create, 4)
  end

  defp stub_route_creates do
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  defp stub_deploy_operands do
    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    stub(Ingress, :delete, fn _kc, _ns, _name ->
      {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
    end)
  end
end
