defmodule FluxVale.Infrastructure.AccessProviders.TailscaleTest do
  @moduledoc false

  # ADR-0039's provider implementation, against stubbed K8s clients (the
  # Instance lifecycle tests' stance): the assertion surface is the call
  # shapes — which objects, with what manifests — and the guard rails
  # (private-only attach, cross-org refusal, the empty Funnel arm).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    # The provider resolves the kubeconfig through the single Cluster row
    # (the instance lifecycle's own placement contract).
    FluxVale.TestSupport.InstanceFixtures.local_cluster!()

    parent = self()

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :create, fn _kc, ns, name, data ->
      send(parent, {:secret_create, ns, name, data})
      {:ok, %{}}
    end)

    stub(Secret, :get_data, fn _kc, _ns, _name -> {:ok, %{"TS_AUTHKEY" => "tskey"}} end)

    stub(PersistentVolumeClaim, :create, fn _kc, ns, name, spec ->
      send(parent, {:pvc_create, ns, name, spec})
      {:ok, %{}}
    end)

    stub(NetworkPolicy, :create, fn _kc, ns, name, spec ->
      send(parent, {:policy_create, ns, name, spec})
      {:ok, %{}}
    end)

    stub(Deployment, :apply_manifest, fn _kc, manifest ->
      send(parent, {:deployment_apply, manifest})
      {:ok, %{}}
    end)

    stub(Deployment, :restart, fn _kc, _ns, _name -> {:ok, %{}} end)
    stub(Deployment, :status, fn _kc, _ns, _name -> {:ok, %{ready: 1, replicas: 1}} end)
    # No provision stub: this file tests the REAL implementation against
    # the stubbed K8s clients above, so building a gateway row exercises
    # the same code path the assertions below cover.

    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance creates carry #124's funded gate.
    {:ok, _wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(org, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  describe "provision_gateway/2" do
    test "writes the credential Secret, the state PVC, the serve config and the pod", %{
      org: org
    } do
      # gateway_row! runs the real create leg through the setup's
      # capturing stubs, so the mailbox holds exactly one provision
      # cycle — the same code path the assertions describe.
      gateway = gateway_row!(org)
      calls = drain()

      secrets = for {:secret_create, _ns, name, data} <- calls, do: {name, data}

      assert {"credential", %{"TS_AUTHKEY" => "tskey"}} in secrets

      assert Enum.any?(secrets, fn {name, data} ->
               name == "serve-config" and is_binary(data["serve.json"])
             end)

      assert Enum.any?(calls, fn
               {:pvc_create, _ns, "state", %{size: "64Mi"}} -> true
               _ -> false
             end)

      manifest =
        Enum.find_value(calls, fn
          {:deployment_apply, manifest} -> manifest
          _ -> false
        end)

      spec = manifest["spec"]["template"]["spec"]
      container = hd(spec["containers"])
      by_name = Map.new(container["env"], &{&1["name"], &1})

      # Zero privileges: no securityContext anywhere (§1).
      refute Map.has_key?(spec, "securityContext")
      refute Map.has_key?(container, "securityContext")

      # The image's own userspace posture, stated explicitly.
      assert by_name["TS_USERSPACE"]["value"] == "true"
      assert by_name["TS_AUTH_ONCE"]["value"] == "true"
      assert by_name["TS_HOSTNAME"]["value"] == gateway.hostname
      assert by_name["TS_SERVE_CONFIG"]["value"] == "/serve/serve.json"
      assert by_name["TS_ENABLE_HEALTH_CHECK"]["value"] == "true"
      # The key rides a secretKeyRef, never a literal value.
      assert by_name["TS_AUTHKEY"]["value_from"]["secretKeyRef"]["name"] == "credential"
      refute Map.has_key?(by_name["TS_AUTHKEY"], "value")
    end

    test "a cluster failure surfaces as an error (the retry's subject)", %{org: org} do
      gateway = gateway_row!(org)
      # Drain the create leg's own captures so only the failing re-apply
      # below is under observation.
      _ = drain()

      expect(Secret, :create, fn _kc, _ns, _name, _data ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.provision_gateway(gateway, "tskey")
    end
  end

  describe "attach_instance/2" do
    test "allocates the first free port and admits the access namespace only", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      assert {:ok, route} = Tailscale.attach_instance(gateway, instance)

      assert_received {:policy_create, ns, "default-deny-ingress", spec}
      assert ns == instance.namespace
      # The gateway's namespace — and NOT the edge namespace, ever
      # (ADR-0038 §5's constraint).
      assert spec.ingress_from_namespaces == [access_namespace()]

      assert route.route_key == "8443"
      assert route.instance_id == instance.id
    end

    test "a second attach takes the next port", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, first} =
        Tailscale.attach_instance(gateway, AccessFixtures.private_instance!(org, owner))

      {:ok, second} =
        Tailscale.attach_instance(gateway, AccessFixtures.private_instance!(org, owner))

      assert first.route_key == "8443"
      assert second.route_key == "8444"
    end

    test "a public instance is refused — one address, not two", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.public_instance!(org, owner)

      assert {:error, :not_private} = Infrastructure.attach_instance(gateway, instance)
    end

    test "a cross-org instance is refused before any cluster write", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      {other_org, other_owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = FluxVale.Billing.ensure_wallet(other_org)
      {:ok, _grant} = FluxVale.Billing.grant_credits(other_org, 10_000, reason: :adjustment)

      instance = AccessFixtures.private_instance!(other_org, other_owner)

      assert {:error, :different_organization} =
               Infrastructure.attach_instance(gateway, instance)
    end

    test "a suspended gateway is refused — a route nobody can reach", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)
      instance = AccessFixtures.private_instance!(org, owner)

      assert {:error, :gateway_not_active} = Infrastructure.attach_instance(gateway, instance)
    end
  end

  describe "detach_instance/2" do
    test "returns the namespace to its private floor and drops the route", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      {:ok, _route} = Tailscale.attach_instance(gateway, instance)

      assert :ok = Tailscale.detach_instance(gateway, instance)

      # Back to same-namespace only — the empty external list.
      assert_received {:policy_create, _ns, "default-deny-ingress", %{ingress_from_namespaces: []}}

      assert {:error, _not_found} =
               FluxVale.Infrastructure.AccessRoute.get_by_instance(instance.id)
    end

    test "detaching an unattached instance is a no-op success", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      assert :ok = Tailscale.detach_instance(gateway, instance)
    end
  end

  describe "gateway_status/1" do
    test "a ready deployment is :active", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)

      expect(Deployment, :status, fn _kc, _ns, "gateway" ->
        {:ok, %{ready: 1, replicas: 1}}
      end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "a created-but-not-ready deployment is :needs_attention", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)

      expect(Deployment, :status, fn _kc, _ns, "gateway" -> {:ok, %{ready: 0, replicas: 1}} end)

      assert {:ok, %{state: :needs_attention}} = Tailscale.gateway_status(gateway)
    end

    test "a missing deployment is :provisioning", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)

      expect(Deployment, :status, fn _kc, _ns, "gateway" ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, %{state: :provisioning}} = Tailscale.gateway_status(gateway)
    end
  end

  describe "read_credential/1" do
    test "returns the key from the Secret — internal only", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)

      expect(Secret, :get_data, fn _kc, _ns, "credential" ->
        {:ok, %{"TS_AUTHKEY" => "tskey"}}
      end)

      assert {:ok, "tskey"} = Tailscale.read_credential(gateway)
    end

    test "a malformed Secret is an explicit error, not a guess", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      stub(Secret, :get_data, fn _kc, _ns, _name -> {:ok, %{}} end)

      assert {:error, :credential_malformed} = Tailscale.read_credential(gateway)
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # A row without the provider's cluster leg — `create` with the provider
  # stubbed (the fixture's stance).
  # A real row, built through the create action — which runs the REAL
  # provision_gateway against the setup's capturing K8s stubs. Nothing
  # here may stub the provider itself: these tests are the provider.
  defp gateway_row!(org) do
    gateway =
      AccessGateway.create!(
        %{organization_id: org.id, monthly_cents: 200, auth_key: "tskey"},
        authorize?: false
      )

    gateway
    |> Ash.Changeset.for_update(:update_state, %{state: :active}, authorize?: false)
    |> Ash.update!()
  end

  defp access_namespace do
    Application.fetch_env!(:flux_vale, :access_gateway)[:namespace] || "fluxvale-access"
  end

  # Everything the stubs captured so far, newest last.
  defp drain(acc \\ []) do
    receive do
      {tag, _, _, _} = msg when tag in [:secret_create, :pvc_create, :policy_create] ->
        drain([msg | acc])

      {:deployment_apply, _} = msg ->
        drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

end
