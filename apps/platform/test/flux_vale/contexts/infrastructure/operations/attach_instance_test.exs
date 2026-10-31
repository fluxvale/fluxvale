defmodule FluxVale.Infrastructure.Operations.AttachInstanceTest do
  @moduledoc false

  # The S2 hook (ADR-0040 §7): the provider lands the pairing, then the
  # operation lands the ACCESS EDGE — the arms per the instance's status
  # and the widened policy — and a failed edge unwinds the row (a row
  # whose limbs never landed claims a pairing nothing can reach). The
  # provider is stubbed; the assertion surface is the access applies.

  use FluxVale.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.AttachInstance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    InstanceFixtures.local_cluster!()
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    # The gateway create runs the provider's provision leg.
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    # The provider's own attach/detach limbs are stubbed: it plays the
    # row-create and stops there (its cluster work is the provider
    # tests' subject).
    stub(Tailscale, :attach_instance, fn gateway, instance ->
      {:ok,
       AccessRoute.create!(
         %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
         authorize?: false
       )}
    end)

    # The access-edge limbs: default success stubs, expect-ed where a
    # test cares.
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :delete, fn _kc, _ns, _n -> not_found() end)
    stub(Middleware, :delete, fn _kc, _ns, _n -> not_found() end)

    # The S4 hook: a committed attach re-renders the resolver view
    # best-effort. Default success; expect-ed where a test cares.
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  defp not_found do
    {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
  end

  test "a :running instance's attach mints the serving arm and the widened policy", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    expect(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, spec ->
      assert spec.entrypoint == "access"
      assert spec.service_name == "app"
      assert spec.middlewares == ["fluxvale-activity"]
      {:ok, %{}}
    end)

    expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
      # The private+attached widening (ADR-0040 Am. 1): the access
      # edge's dial joins the pod-narrowed gateway peer.
      namespaces = Enum.map(spec.ingress_from_sources, & &1.namespace)

      assert Application.fetch_env!(:flux_vale, :instance_ingress_namespace) in namespaces

      gateway_peer = Enum.find(spec.ingress_from_sources, &(&1.namespace == "fluxvale-access"))
      assert gateway_peer.match_labels == gateway_pod_labels(gateway)

      {:ok, %{}}
    end)

    assert {:ok, _route} = AttachInstance.call(gateway, instance)
  end

  test "a :sleeping instance's attach mints the wake arm — the pair in the path", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = private_at!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    expect(Middleware, :create, fn _kc, ^ns, "fluxvale-access-wake", spec ->
      assert spec.replace_path_regex == %{
               regex: "^/(.*)",
               replacement: "/internal/access/#{gateway.id}/#{instance.id}/$1"
             }

      {:ok, %{}}
    end)

    expect(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, spec ->
      assert spec.service_name == "wake"
      assert spec.middlewares == ["fluxvale-access-wake"]
      {:ok, %{}}
    end)

    assert {:ok, _route} = AttachInstance.call(gateway, instance)
  end

  test "an access-arm failure fails the attach and removes the row", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    stub(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, _spec ->
      {:error, Error.connection_error("access refused")}
    end)

    assert {:error, error} = AttachInstance.call(gateway, instance)
    assert inspect(error) =~ "access refused"

    # The row-claims-nothing discipline: the pairing is gone, so a
    # retry starts clean (the provider's attach is idempotent).
    assert {:error, _not_found} = AccessRoute.get_by_instance(instance.id, authorize?: false)
  end

  test "a policy-widening failure fails the attach and removes the row", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", _spec ->
      {:error, Error.connection_error("policy refused")}
    end)

    assert {:error, _error} = AttachInstance.call(gateway, instance)

    assert {:error, _not_found} = AccessRoute.get_by_instance(instance.id, authorize?: false)
  end

  test "a pending instance (no namespace) attaches as a clean refusal", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    attached = AccessFixtures.private_instance!(org, owner)
    instance = InstanceFixtures.pin!(attached, namespace: nil)

    # The provider must never be reached — the guard is the operation's.
    stub(Tailscale, :attach_instance, fn _gateway, _instance ->
      flunk("a nil-namespace instance must be refused before the provider")
    end)

    assert {:error, :not_deployed} = AttachInstance.call(gateway, instance)
  end

  test "an arm failure on an idempotent retry leaves the pre-existing pairing", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    # The pairing predates this attempt (the idempotent-retry shape):
    # the provider answers the SAME row it finds.
    {:ok, existing} =
      AccessRoute.create(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

    stub(Tailscale, :attach_instance, fn _gateway, _instance -> {:ok, existing} end)

    stub(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, _spec ->
      {:error, Error.connection_error("access refused")}
    end)

    assert {:error, _reason} = AttachInstance.call(gateway, instance)

    # The row-claims-nothing unwind must NOT destroy a pairing this
    # attempt did not create (the S1 three-vs-four-arg lesson).
    assert {:ok, survivor} = AccessRoute.get_by_instance(instance.id, authorize?: false)
    assert survivor.id == existing.id
  end

  test "an attach that races a sleep re-applies the arm per the fresh status", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    parent = self()

    # Stage the interleaving: the row commits :sleeping while the attach
    # is in flight, so the minted serving arm is stale the moment it
    # lands.
    stub(Tailscale, :attach_instance, fn gw, inst ->
      {:ok, _route} =
        AccessRoute.create(
          %{gateway_id: gw.id, instance_id: inst.id, route_key: "8443"},
          authorize?: false
        )

      AccessFixtures.sleep!(inst)

      {:ok, AccessRoute.get_by_instance!(inst.id, authorize?: false)}
    end)

    stub(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, spec ->
      send(parent, {:access_route, spec})
      {:ok, %{}}
    end)

    assert {:ok, _route} = AttachInstance.call(gateway, instance)

    services = Enum.map(drain_access_specs(), & &1.service_name)

    # Serving first (the in-hand status), then the ONE bounded re-apply
    # per the fresh (sleeping) status — the maybe_recheck pattern.
    assert services == ["app", "wake"]
  end

  # The re-apply's failure arm: it must not retro-fail the attach (the
  # row and the first arm stand), but it must not vanish silently either.
  test "a failed fresh-status re-apply is logged and the attach still stands", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    # Stage the same interleaving as the race above, but fail the
    # re-apply: the first (in-hand serving) mint lands, the fresh-status
    # wake re-apply is refused.
    stub(Tailscale, :attach_instance, fn gw, inst ->
      {:ok, _route} =
        AccessRoute.create(
          %{gateway_id: gw.id, instance_id: inst.id, route_key: "8443"},
          authorize?: false
        )

      AccessFixtures.sleep!(inst)

      {:ok, AccessRoute.get_by_instance!(inst.id, authorize?: false)}
    end)

    stub(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, _spec ->
      n = Process.get(:arm_mints, 0) + 1
      Process.put(:arm_mints, n)

      if n == 1 do
        {:ok, %{}}
      else
        {:error, Error.connection_error("re-apply refused")}
      end
    end)

    log =
      capture_log(fn ->
        assert {:ok, _route} = AttachInstance.call(gateway, instance)
      end)

    assert log =~ "re-apply failed"
    assert log =~ "re-apply refused"

    # The primary result stands: the pairing row survives (no unwind).
    assert {:ok, _row} = AccessRoute.get_by_instance(instance.id, authorize?: false)
  end

  defp drain_access_specs(acc \\ []) do
    receive do
      {:access_route, spec} -> drain_access_specs([spec | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the S4 render hook (ADR-0040 §4)" do
    test "a committed attach re-renders the resolver view", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _route} = AttachInstance.call(gateway, instance)
    end

    test "a failed access edge never re-renders (the row unwinds)", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      # The access mint fails mid-flight: no view render may ride a
      # failed primary — the 15-min pass is the convergence owner.
      stub(Ingress, :create, fn _kc, _ns, _n, _spec ->
        {:error, Error.from_response({:ok, %{status: 403, body: %{}}})}
      end)

      stub(RenderAccessDNS, :call, fn -> flunk("no render on a failed primary") end)
      stub(RenderAccessDNS, :call, fn _opts -> flunk("no render on a failed primary") end)

      assert {:error, _reason} = AttachInstance.call(gateway, instance)
    end
  end

  defp gateway_pod_labels(gateway), do: InstanceK8s.gateway_pod_labels(gateway.id)

  # A private instance at :sleeping — the funnel's own write from
  # :running (AccessFixtures.sleep!/1).
  defp private_at!(org, owner) do
    org
    |> then(&AccessFixtures.private_instance!(&1, owner))
    |> AccessFixtures.sleep!()
  end
end
