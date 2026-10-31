defmodule FluxVale.Infrastructure.AccessProviders.TailscaleTest do
  @moduledoc false

  # ADR-0039's provider implementation, against stubbed K8s clients (the
  # Instance lifecycle tests' stance): the assertion surface is the call
  # shapes — which objects, with what manifests — and the guard rails
  # (private-only attach, cross-org refusal, the empty Funnel arm).

  use FluxVale.DataCase, async: true
  use Mimic

  alias Ash.Error.Query.NotFound
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  setup do
    # The provider resolves the kubeconfig through the single Cluster row
    # (the instance lifecycle's own placement contract).
    InstanceFixtures.local_cluster!()

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

      assert {name("credential", gateway), %{"TS_AUTHKEY" => "tskey"}} in secrets

      # The P1 contract on the provision-time config: valid JSON, and no
      # unexpanded placeholder anywhere in what we write. Provision has
      # no routes yet, so the Web arm is empty — the concrete-FQDN keys
      # are pinned by the attach tests below.
      serve_json =
        Enum.find_value(secrets, fn {secret_name, data} ->
          if secret_name == name("serve-config", gateway), do: data["serve.json"]
        end)

      assert is_binary(serve_json)
      assert serve_json =~ "\"TCP\""
      refute serve_json =~ "${"
      refute serve_json =~ "TS_CERT_DOMAIN"

      assert Enum.any?(calls, fn
               {:pvc_create, _ns, claim, %{size: "64Mi"}} ->
                 claim == name("state", gateway)

               _other_call ->
                 false
             end)

      manifest =
        Enum.find_value(calls, fn
          {:deployment_apply, manifest} -> manifest
          _other_call -> false
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
      assert by_name["TS_AUTHKEY"]["valueFrom"]["secretKeyRef"]["name"] ==
               name("credential", gateway)

      refute Map.has_key?(by_name["TS_AUTHKEY"], "value")
    end

    test "a cluster failure surfaces an error and LEAVES the key for the retry", %{org: org} do
      gateway = gateway_row!(org)
      # Drain the create leg's own captures so only the failing re-apply
      # below is under observation.
      drain()

      # The credential write succeeds, a later step fails. The Secret must
      # SURVIVE: `:provision`'s drift repair re-reads its key from exactly
      # this Secret, so deleting it here would turn a transient cluster
      # error into an unrepairable gateway.
      expect(Secret, :create, fn _kc, _ns, _name, _data -> {:ok, %{}} end)

      expect(Deployment, :apply_manifest, fn _kc, _manifest ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      reject(Secret, :delete, 3)

      assert {:error, %Error{}} = Tailscale.provision_gateway(gateway, "tskey")
    end
  end

  describe "attach_instance/2" do
    test "allocates the first free port and admits the access namespace only", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      assert {:ok, route} = Tailscale.attach_instance(gateway, instance)

      assert_received {:policy_create, ns, "default-deny-ingress", spec}
      assert ns == instance.namespace

      # The gateway's namespace — and NOT the edge namespace, ever
      # (ADR-0038 §5's constraint).
      assert [peer] = spec.ingress_from_sources
      assert peer.namespace == access_namespace()

      # THE LOAD-BEARING LINE: without this pod selector the policy admits
      # every pod in the shared access namespace, so org B's gateway
      # reaches org A's app. Dropping it must fail a test, not silently
      # degrade the tenancy boundary.
      assert peer.match_labels == InstanceK8s.gateway_pod_labels(gateway.id)

      refute Enum.any?(spec.ingress_from_sources, &(&1.namespace == edge_namespace()))

      assert route.route_key == "8443"
      assert route.instance_id == instance.id

      # THE OTHER LOAD-BEARING LINE (the P1 fix): the written serve
      # config keys the port under the CONCRETE FQDN — hostname joined
      # to the row's owner-provided tailnet domain — so real SNI
      # matches. The first cut wrote "<hostname>.${TS_CERT_DOMAIN}"
      # and the gateway answered every handshake with "no webserver
      # configured for name/port".
      config = latest_serve_config()

      assert config =~
               ~s("#{gateway.hostname}.#{gateway.tailnet_domain}:#{route.route_key}")

      refute config =~ "${"
    end

    test "a pre-column row with no tailnet domain is refused, not written broken", %{
      org: org,
      owner: owner
    } do
      # The migration-window shape: the live staging gateway predates
      # the column, so no action can build it — seed! is the one
      # sanctioned route to a state actions can't produce.
      gateway =
        Ash.Seed.seed!(AccessGateway, %{
          organization_id: org.id,
          hostname: "fv-00000001",
          monthly_cents: 200,
          state: :active,
          tailnet_domain: nil
        })

      instance = AccessFixtures.private_instance!(org, owner)

      assert {:error, :tailnet_domain_missing} = Tailscale.attach_instance(gateway, instance)

      # The cleanup arm ran: no route row survives a refused attach (a
      # leftover would read as the owner's consent for a wake it never
      # got service for — the provider's own stance).
      assert {:error, _not_found} = AccessRoute.get_by_instance(instance.id, authorize?: false)
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

    test "a cross-org instance is refused before any cluster write", %{org: org} do
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

  describe "attach idempotence (the retry must not unwind a good pairing)" do
    test "attaching the same instance twice returns the existing route", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      {:ok, first} = Tailscale.attach_instance(gateway, instance)
      {:ok, second} = Tailscale.attach_instance(gateway, instance)

      # Same pairing, same port — not a second route that the unique
      # index would reject and cleanup would then delete.
      assert second.id == first.id
      assert second.route_key == first.route_key
      assert {:ok, still} = AccessRoute.get_by_instance(instance.id, authorize?: false)
      assert still.id == first.id
    end

    test "a route on ANOTHER gateway is not adopted", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, original} = Tailscale.attach_instance(gateway, instance)

      # A second gateway for a different org must not treat the first
      # org's route as its own pairing.
      {other_org, other_owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = FluxVale.Billing.ensure_wallet(other_org)
      {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)
      other_gateway = AccessFixtures.gateway!(other_org)
      other_instance = AccessFixtures.private_instance!(other_org, other_owner)

      {:ok, route} = Tailscale.attach_instance(other_gateway, other_instance)

      assert route.instance_id == other_instance.id
      assert {:ok, kept} = AccessRoute.get_by_instance(instance.id, authorize?: false)
      assert kept.id == original.id
    end
  end

  describe "a suspended gateway's re-paste" do
    test "writes the key but does NOT restart the parked pod", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      # A restart is a get→apply asserting the fetched replica count, so
      # it would resurrect a pod the ladder scaled to 0 — and the
      # observer refuses to override a suspension, so it would serve free.
      reject(Deployment, :restart, 3)

      assert :ok = Tailscale.update_credential(gateway, "tskey-new")

      assert_received {:secret_create, _ns, credential, %{"TS_AUTHKEY" => "tskey-new"}}
      assert credential == name("credential", gateway)
    end
  end

  describe "an instance destroyed under an attach" do
    test "its route goes with it (the FK), so attach retries cleanly", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, route} = Tailscale.attach_instance(gateway, instance)

      FluxVale.Repo.query!("DELETE FROM instances WHERE id = $1", [
        Ecto.UUID.dump!(instance.id)
      ])

      # The pairing has no meaning without the instance.
      assert {:error, _not_found} = AccessRoute.get_by_instance(instance.id, authorize?: false)
      assert is_binary(route.id)
    end
  end

  describe "the pod's rollout strategy" do
    test "is Recreate — the RWO state PVC carries the node identity", %{org: org} do
      gateway = gateway_row!(org)
      calls = drain()

      manifest =
        Enum.find_value(calls, fn
          {:deployment_apply, m} -> m
          _other -> false
        end)

      # RollingUpdate would start the new pod before the old stops: a
      # double-mount of the node identity on one node, or a Multi-Attach
      # timeout across nodes, on every re-paste restart.
      assert manifest["spec"]["strategy"]["type"] == "Recreate"
    end
  end

  describe "a lost Deployment on an active gateway" do
    test "is drift, not a fresh provision — it stops reporting Connected", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      assert gateway.state == :active

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      # Not :provisioning (the panel would say "Setting up access"
      # forever and metering would continue against a pod that is gone).
      # The message renders on the panel (the row's status_message), so
      # it is pinned copy: friendly (#179's split — the old text named a
      # platform term) and affordance-honest (update_credential's drift
      # repair makes reconnect the real recovery; no dead support
      # pointer).
      assert {:ok,
              %{
                state: :needs_attention,
                message: "Not connected — your access setup was lost; reconnect with a fresh key"
              }} = Tailscale.gateway_status(gateway)
    end
  end

  describe "cleanup_failed_provision/1 (the create rollback)" do
    test "removes the key, the serve config and the PVC", %{org: org} do
      gateway = gateway_row!(org)

      expect(Secret, :delete, 2, fn _kc, _ns, secret_name ->
        assert secret_name in [name("credential", gateway), name("serve-config", gateway)]
        :ok
      end)

      expect(PersistentVolumeClaim, :delete, fn _kc, _ns, claim ->
        assert claim == name("state", gateway)
        :ok
      end)

      assert :ok = Tailscale.cleanup_failed_provision(gateway)
    end

    test "deletes the KEY first — it is the object a stranger could use", %{org: org} do
      gateway = gateway_row!(org)
      parent = self()

      stub(Secret, :delete, fn _kc, _ns, secret_name ->
        send(parent, {:deleted, secret_name})
        :ok
      end)

      stub(PersistentVolumeClaim, :delete, fn _kc, _ns, _claim -> :ok end)

      assert :ok = Tailscale.cleanup_failed_provision(gateway)

      assert_received {:deleted, first}
      assert first == name("credential", gateway)
    end
  end

  describe "credential write failures" do
    test "a Secret write failure surfaces from provision", %{org: org} do
      gateway = gateway_row!(org)

      expect(Secret, :create, fn _kc, _ns, _name, _data ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      # No cleanup on failure any more (the retry needs the key it wrote).
      reject(Secret, :delete, 3)

      assert {:error, %Error{}} = Tailscale.provision_gateway(gateway, "tskey")
    end
  end

  describe "the provider's own private guard" do
    # The operation refuses a public instance first; the provider guards
    # too, so a direct caller (the wake path, a future API) cannot mint a
    # second address for an instance that already has one.
    test "a public instance is refused at the provider, not only upstream", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.public_instance!(org, owner)

      assert {:error, :not_private} = Tailscale.attach_instance(gateway, instance)
    end
  end

  describe "two concurrent attaches (P3-3)" do
    # Both racers share ONE gateway (the resource is unique per org), so a
    # gateway-scoped delete cannot tell the winner's row from the loser's.
    # Only "did this attempt create it" can. The loser must leave the
    # winner's committed pairing untouched.
    test "a loser of the unique index deletes NOTHING of the winner's", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      # The winner's committed pairing — the row a gateway-scoped delete
      # would find and (wrongly) destroy.
      {:ok, winner} =
        AccessRoute.create(
          %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
          authorize?: false
        )

      # The loser ran `existing_route` BEFORE the winner committed (so it
      # saw :none), then lost `unique_instance`. Both halves of that
      # interleave are injected: the guard's read returns not-found (the
      # pre-commit view), and the create returns the index violation.
      # Reordering them sequentially is impossible — the guard would
      # short-circuit into the no-op success that is the common case.
      reject(AccessRoute, :destroy, 2)

      # `stub` (not `expect`): the guard's read is consulted once here, and
      # the assertion below reads the same function again.
      stub(AccessRoute, :get_by_instance, fn _id, _opts ->
        {:error, NotFound.exception(resource: AccessRoute)}
      end)

      expect(AccessRoute, :create, fn _attrs, _opts -> {:error, unique_violation()} end)

      assert {:error, _reason} = Tailscale.attach_instance(gateway, instance)

      # Still there, untouched: the loser never created it. Read through
      # Ash directly (the stub above owns the provider-facing function).
      assert [kept] =
               AccessRoute
               |> Ash.Query.filter(instance_id == ^instance.id)
               |> Ash.read!(authorize?: false)

      assert kept.id == winner.id
      assert kept.route_key == "8443"
    end

    test "cleanup after a cluster failure deletes only this gateway's route", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      # A route for the instance that belongs to a DIFFERENT gateway (a
      # moved instance's old pairing). Cleanup for this gateway must leave
      # it alone — `delete_route/2` is scoped, and the other gateway's
      # teardown is what owns that row.
      {other_org, _other_owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = FluxVale.Billing.ensure_wallet(other_org)
      {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)
      other_gateway = AccessFixtures.gateway!(other_org)

      {:ok, foreign} =
        AccessRoute.create(
          %{gateway_id: other_gateway.id, instance_id: instance.id, route_key: "8499"},
          authorize?: false
        )

      # The create collides on `unique_instance` (the foreign row holds it),
      # so the attach fails BEFORE any cleanup runs. That is the desired
      # end state too: nothing of this gateway's was created, so nothing is
      # deleted.
      assert {:error, _reason} = Tailscale.attach_instance(gateway, instance)

      # Its own row is gone; the foreign one survives untouched.
      rows =
        AccessRoute
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read!(authorize?: false)

      assert Enum.map(rows, & &1.id) == [foreign.id]
    end

    test "a winner's committed route survives a later loser", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      # The winner's pairing is committed first.
      {:ok, winner} = Tailscale.attach_instance(gateway, instance)

      # A retry now converges on it rather than racing — the guard is
      # what makes the common case a no-op, and it returns the SAME row.
      {:ok, again} = Tailscale.attach_instance(gateway, instance)

      assert again.id == winner.id

      assert {:ok, kept} = AccessRoute.get_by_instance(instance.id, authorize?: false)
      assert kept.id == winner.id
      assert kept.route_key == winner.route_key
    end
  end

  describe "attach failures clean up after themselves" do
    # The policy write is the last step: if it fails, the route row that
    # already landed must not survive — a leftover row would hold a port
    # and read as consent for a wake the owner never got service for.
    test "a policy failure removes the route it just created", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      expect(NetworkPolicy, :create, fn _kc, _ns, _name, _spec ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.attach_instance(gateway, instance)

      assert {:error, _not_found} = AccessRoute.get_by_instance(instance.id, authorize?: false)
    end

    # The detach-side 404 arm (namespace gone = posture already holding)
    # must never reach here: on attach the namespace being gone means
    # the deployment never existed, so a 404 is a real failure.
    test "a 404 on the policy write fails attach — the asymmetry with detach", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      expect(NetworkPolicy, :create, fn _kc, _ns, _name, _spec ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:error, %Error{reason: :not_found}} = Tailscale.attach_instance(gateway, instance)

      assert {:error, _not_found} = AccessRoute.get_by_instance(instance.id, authorize?: false)
    end
  end

  describe "detach_instance/2" do
    test "returns the namespace to its private floor and drops the route", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      {:ok, _route} = Tailscale.attach_instance(gateway, instance)

      assert :ok = Tailscale.detach_instance(gateway, instance)

      # Back to same-namespace only — the empty external list.
      assert_received {:policy_create, _ns, "default-deny-ingress",
                       %{ingress_from_namespaces: []}}

      assert {:error, _not_found} =
               AccessRoute.get_by_instance(instance.id, authorize?: false)
    end

    test "a missing instance namespace is the posture already holding — 404 on detach is :ok",
         %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, _route} = Tailscale.attach_instance(gateway, instance)

      # Mimic the case where the instance cluster deleted the namespace
      # after attach, so Policy.create returns :not_found on detach.
      expect(NetworkPolicy, :create, fn _kc, ns, _pn, _spec ->
        assert ns == instance.namespace
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      # The route is present when detach starts, then deleted by the tear-down.
      assert {:ok, %AccessRoute{}} =
               AccessRoute.get_by_instance(instance.id, authorize?: false)

      assert :ok = Tailscale.detach_instance(gateway, instance)

      # Detach succeeds, then the route row is gone.
      assert {:error, _not_found} =
               AccessRoute.get_by_instance(instance.id, authorize?: false)
    end

    test "detaching an unattached instance is a no-op success", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      assert :ok = Tailscale.detach_instance(gateway, instance)
    end
  end

  describe "gateway_status/1" do
    test "a ready deployment is :active", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Deployment, :status, fn _kc, _ns, deployment ->
        assert deployment == name("gateway", gateway)

        {:ok,
         %{
           ready: 1,
           replicas: 1,
           actual_replicas: 1,
           updated: 1,
           generation: 1,
           observed_generation: 1
         }}
      end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "a created-but-not-ready deployment is :needs_attention", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Deployment, :status, fn _kc, _ns, deployment ->
        assert deployment == name("gateway", gateway)

        {:ok,
         %{
           ready: 0,
           replicas: 1,
           actual_replicas: 1,
           updated: 1,
           generation: 1,
           observed_generation: 1
         }}
      end)

      assert {:ok, %{state: :needs_attention}} = Tailscale.gateway_status(gateway)
    end

    test "a missing deployment on a fresh row is :provisioning", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :provisioning)

      expect(Deployment, :status, fn _kc, _ns, deployment ->
        assert deployment == name("gateway", gateway)
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, %{state: :provisioning}} = Tailscale.gateway_status(gateway)
    end
  end

  describe "refresh_routes/1" do
    test "regenerates the config from the rows — asleep targets the wake endpoint, awake the app",
         %{
           org: org,
           owner: owner
         } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, _route} = Tailscale.attach_instance(gateway, instance)

      # Asleep in the DB: with the intercept on (#273) the regenerated
      # config must point the port at the platform's wake endpoint, so a
      # gateway request wakes the instance (ADR-0039 §6's sleep-side).
      {:ok, sleeping} = InstanceK8s.update_status(instance, :sleeping, nil)
      {:ok, _secret} = Tailscale.refresh_routes(gateway)

      config = latest_serve_config()
      assert config =~ "/internal/access/#{gateway.id}/#{instance.id}"
      refute config =~ "app.#{instance.namespace}.svc.cluster.local:80"

      # And back: running re-targets the app Service (the wake
      # endpoint's flip — ADR-0039 §6's wake-side).
      {:ok, starting} = InstanceK8s.update_status(sleeping, :starting, nil)
      {:ok, _running} = InstanceK8s.update_status(starting, :running, nil)
      {:ok, _secret} = Tailscale.refresh_routes(gateway)

      awake_config = latest_serve_config()
      assert awake_config =~ "app.#{instance.namespace}.svc.cluster.local:80"
      refute awake_config =~ "/internal/access/"
    end

    test "regenerates the WHOLE config — a vanished route's port leaves the written Secret", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance_a = AccessFixtures.private_instance!(org, owner)
      instance_b = AccessFixtures.private_instance!(org, owner)
      {:ok, route_a} = Tailscale.attach_instance(gateway, instance_a)
      {:ok, route_b} = Tailscale.attach_instance(gateway, instance_b)

      # B's pairing row vanishes out-of-band (the race a concurrent
      # teardown's row delete produces): the mounted config still
      # carries B's port until a regeneration reads the rows.
      AccessRoute.destroy(route_b, authorize?: false)

      {:ok, _secret} = Tailscale.refresh_routes(gateway)

      config = latest_serve_config()
      assert config =~ route_a.route_key
      refute config =~ route_b.route_key
    end
  end

  describe "update_credential/2" do
    test "writes the Secret and restarts the pod", %{org: org} do
      gateway = gateway_row!(org)

      expect(Deployment, :restart, fn _kc, _ns, deployment ->
        assert deployment == name("gateway", gateway)
        {:ok, %{}}
      end)

      assert :ok = Tailscale.update_credential(gateway, "tskey-new")

      assert_received {:secret_create, _ns, credential, %{"TS_AUTHKEY" => "tskey-new"}}
      assert credential == name("credential", gateway)
    end

    test "a restart failure surfaces", %{org: org} do
      gateway = gateway_row!(org)

      expect(Deployment, :restart, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.update_credential(gateway, "tskey-new")
    end

    test "a :provisioning row's re-paste is the drift repair — re-applies, no restart", %{
      org: org
    } do
      # create! lands :provisioning: the row whose objects never landed
      # (or were lost) — the shape the drift repair exists for.
      gateway = gateway_row!(org, :provisioning)
      parent = self()

      # SSA re-apply — the same call the create path makes — never the
      # restart, which is a get→apply that 404s on the missing object.
      stub(Deployment, :apply_manifest, fn _kc, manifest ->
        send(parent, {:deployment_apply, manifest})
        {:ok, %{}}
      end)

      reject(Deployment, :restart, 3)

      assert :ok = Tailscale.update_credential(gateway, "tskey-new")

      assert_received {:secret_create, _ns, credential, %{"TS_AUTHKEY" => "tskey-new"}}
      assert credential == name("credential", gateway)
      assert_received {:deployment_apply, _manifest}
    end

    test "a failed re-apply surfaces", %{org: org} do
      gateway = gateway_row!(org, :provisioning)

      expect(Secret, :create, fn _kc, _ns, _name, _data ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.update_credential(gateway, "tskey-new")
    end
  end

  describe "scale_gateway/2" do
    test "scales to zero and to one", %{org: org} do
      gateway = gateway_row!(org)

      expect(Deployment, :scale, fn _kc, _ns, deployment, 0 ->
        assert deployment == name("gateway", gateway)
        {:ok, %{}}
      end)

      assert :ok = Tailscale.scale_gateway(gateway, 0)

      expect(Deployment, :scale, fn _kc, _ns, deployment, 1 ->
        assert deployment == name("gateway", gateway)
        {:ok, %{}}
      end)

      assert :ok = Tailscale.scale_gateway(gateway, 1)
    end

    test "a scale failure surfaces", %{org: org} do
      gateway = gateway_row!(org)

      expect(Deployment, :scale, fn _kc, _ns, _n, _r ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.scale_gateway(gateway, 0)
    end
  end

  describe "a detach failure during teardown (P3-4)" do
    test "fails the teardown instead of deleting objects and claiming success", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, _route} = Tailscale.attach_instance(gateway, instance)

      # The instance's policy restore fails. Deleting the objects anyway
      # would leave that policy entry pointing at this gateway's labels
      # with nothing ever returning it to the private floor, and report
      # success — the teardown's "detach-first is the contract" lie.
      expect(NetworkPolicy, :create, fn _kc, _ns, _n, _spec ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      reject(Deployment, :delete, 3)

      assert {:error, {:detach_failed, _instance_id, _reason}} =
               Tailscale.teardown_gateway(gateway)
    end

    test "a clean detach still tears everything down", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, _route} = Tailscale.attach_instance(gateway, instance)

      expect(Deployment, :delete, fn _kc, _ns, _n -> :ok end)
      expect(Secret, :delete, 2, fn _kc, _ns, _n -> :ok end)
      expect(PersistentVolumeClaim, :delete, fn _kc, _ns, _n -> :ok end)

      assert :ok = Tailscale.teardown_gateway(gateway)
    end
  end

  describe "teardown_gateway/1" do
    test "detaches attached instances, then deletes every object", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, _route} = Tailscale.attach_instance(gateway, instance)

      expect(Deployment, :delete, fn _kc, _ns, deployment ->
        assert deployment == name("gateway", gateway)
        :ok
      end)

      expect(Secret, :delete, 2, fn _kc, _ns, secret_name ->
        # Both the credential and the serve config, both per-gateway.
        assert secret_name in [
                 name("credential", gateway),
                 name("serve-config", gateway)
               ]

        :ok
      end)

      expect(PersistentVolumeClaim, :delete, fn _kc, _ns, claim ->
        assert claim == name("state", gateway)
        :ok
      end)

      assert :ok = Tailscale.teardown_gateway(gateway)

      # The instance is back to panel-only private: its route is gone.
      assert {:error, _not_found} = AccessRoute.get_by_instance(instance.id, authorize?: false)
    end

    test "a missing object is the posture already holding — 404 is success", %{org: org} do
      gateway = gateway_row!(org)

      not_found = Error.from_response({:ok, %{status: 404, body: %{}}})

      expect(Deployment, :delete, fn _kc, _ns, _n -> {:error, not_found} end)
      expect(Secret, :delete, 2, fn _kc, _ns, _n -> {:error, not_found} end)
      expect(PersistentVolumeClaim, :delete, fn _kc, _ns, _n -> {:error, not_found} end)

      assert :ok = Tailscale.teardown_gateway(gateway)
    end

    test "a real delete failure surfaces for the retry", %{org: org} do
      gateway = gateway_row!(org)

      expect(Deployment, :delete, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.teardown_gateway(gateway)
    end
  end

  describe "Secret read/write failures" do
    test "read_credential surfaces a Secret read error", %{org: org} do
      gateway = gateway_row!(org)

      expect(Secret, :get_data, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.read_credential(gateway)
    end

    test "a serve-config Secret write failure surfaces from attach", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      # The credential + policy writes succeed; the serve-config write
      # (the routing table) fails.
      serve_name = name("serve-config", gateway)

      stub(Secret, :create, fn _kc, _ns, name, _data ->
        if name == serve_name do
          {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
        else
          {:ok, %{}}
        end
      end)

      assert {:error, %Error{}} = Tailscale.attach_instance(gateway, instance)
    end

    test "an unexpected status read error surfaces", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.gateway_status(gateway)
    end
  end

  describe "policy edge shapes" do
    # An instance that was never deployed has no namespace: attach is a
    # no-op on the policy side (the deploy will apply the posture).
    test "attaching a never-deployed instance skips the policy", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      undeployed = %{instance | namespace: nil}

      assert {:ok, _route} = Tailscale.attach_instance(gateway, undeployed)
      refute_received {:policy_create, _ns, _name, _spec}
    end

    test "detaching never deployed is a no-op", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      assert :ok = Tailscale.detach_instance(gateway, %{instance | namespace: nil})
      refute_received {:policy_create, _ns, _name, _spec}
    end

    # A public instance's policy admits the edge; detaching must not
    # narrow that (the two switches are independent, §3).
    test "detaching a public instance leaves its edge policy alone", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.public_instance!(org, owner)

      assert :ok = Tailscale.detach_instance(gateway, instance)
      refute_received {:policy_create, _ns, _name, _spec}
    end
  end

  describe "gateway_status/1 — the suspended shape" do
    test "a scaled-to-zero pod reports the row's own state", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      expect(Deployment, :status, fn _kc, _ns, deployment -> {:ok, %{ready: 0, replicas: 0}} end)

      assert {:ok, %{state: :suspended}} = Tailscale.gateway_status(gateway)
    end
  end

  describe "placement" do
    test "no cluster row is an explicit error, never a guess", %{org: org} do
      gateway = gateway_row!(org)

      clusters = Ash.read!(FluxVale.Infrastructure.Cluster, authorize?: false)
      Enum.each(clusters, &Ash.destroy!(&1, authorize?: false))

      assert {:error, :no_cluster} = Tailscale.scale_gateway(gateway, 0)
    end
  end

  describe "read_credential/1" do
    test "returns the key from the Secret — internal only", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Secret, :get_data, fn _kc, _ns, credential ->
        {:ok, %{"TS_AUTHKEY" => "tskey"}}
      end)

      assert {:ok, "tskey"} = Tailscale.read_credential(gateway)
    end

    test "a malformed Secret is an explicit error, not a guess", %{org: org} do
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
  defp gateway_row!(org, state \\ :active) do
    gateway =
      AccessGateway.create!(
        %{
          organization_id: org.id,
          monthly_cents: 200,
          tailnet_domain: "example.ts.net",
          auth_key: "tskey"
        },
        authorize?: false
      )

    gateway
    |> Ash.Changeset.for_update(:update_state, %{state: state, status_message: "Connected"},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp access_namespace do
    # The one resolver — the old `|| "fluxvale-access"` fallback here was
    # the second resolver this PR deleted from production; keeping it
    # would let the suite assert the fallback shape while production
    # raises.
    InstanceK8s.gateway_access_namespace()
  end

  defp unique_violation do
    %Ash.Error.Changes.InvalidAttribute{
      field: :instance_id,
      message: "has already been taken",
      private_vars: [constraint: "access_routes_unique_instance_index"]
    }
  end

  defp edge_namespace, do: Application.fetch_env!(:flux_vale, :instance_ingress_namespace)

  # The per-gateway object names (ADR-0039 §1's multi-tenancy fix): the
  # provider keys every object by the RANDOM TAIL of the gateway id (a
  # uuid v7's leading hex is a timestamp, shared by everything created in
  # the same window).
  defp name(prefix, gateway) do
    suffix =
      gateway.id
      |> to_string()
      |> String.replace("-", "")
      |> String.slice(-10, 10)

    "#{prefix}-#{suffix}"
  end

  # The most recent serve config the provider wrote (the Secret's
  # payload), for the routing assertions.
  defp latest_serve_config do
    calls = drain()

    calls
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:secret_create, _ns, secret_name, %{"serve.json" => json}} ->
        if String.starts_with?(secret_name, "serve-config"), do: json

      _other_call ->
        nil
    end)
  end

  # Everything the stubs captured so far, newest last.
  defp drain(acc \\ []) do
    receive do
      {tag, ns, name, data}
      when tag in [:secret_create, :pvc_create, :policy_create] ->
        drain([{tag, ns, name, data} | acc])

      {:deployment_apply, manifest} ->
        drain([{:deployment_apply, manifest} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
