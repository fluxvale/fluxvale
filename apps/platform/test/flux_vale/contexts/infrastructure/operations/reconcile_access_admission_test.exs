defmodule FluxVale.Infrastructure.Operations.ReconcileAccessAdmissionTest do
  @moduledoc false

  # ADR-0040 Am. 6: the one-minute admission pass — a gateway's pod
  # address moved, the paired private instances' routes follow it. The
  # cluster is stubbed; the assertion surfaces are the memo
  # (`Edge.Activity`) and the access applies.

  use FluxVale.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Pod
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Edge.Activity
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.ReconcileAccessAdmission
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    InstanceFixtures.local_cluster!()
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    # The gateway create runs the provider's provision leg.
    stub(FluxVale.Infrastructure.AccessProviders.Tailscale, :provision_gateway, fn _gateway,
                                                                                   _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    # The access-edge limbs: default success stubs, expect-ed or
    # re-stubbed where a test cares.
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Middleware, :delete, fn _kc, _ns, _n -> :ok end)

    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    # The memo is the app GenServer's global state shared by the whole
    # suite: this file's entries are swept on exit (tests here run
    # serially with the rest of the non-async suite).
    on_exit(fn ->
      Enum.each(Activity.admitted_source_ids(), &Activity.forget_admitted_source/1)
    end)

    {org, owner} = funded_org!()
    {:ok, org: org, owner: owner}
  end

  test "an unreachable platform cluster fails the pass" do
    stub(K8s, :kubeconfig, fn -> {:error, :no_cluster} end)

    assert {:error, :no_cluster} = ReconcileAccessAdmission.call()
  end

  test "the first pass converges every paired gateway; the next pass with the same address is a no-op",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    stub_gateway_pods(%{gateway.id => "10.0.0.1"})
    stub_ingress_sends()

    assert {:ok, %{checked: 1, converged: 1}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(gateway.id) == "10.0.0.1"

    created = drain_access_ingresses()
    assert [%{source_ip: "10.0.0.1"} | _rest] = specs_in(created, instance.namespace)

    # Same address: the memo matches, nothing re-applies or re-renders.
    assert {:ok, %{checked: 1, converged: 0}} = ReconcileAccessAdmission.call()
    assert drain_access_ingresses() == []
  end

  test "a pod move re-applies the arms with the new address and re-renders the resolver view once",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    stub_gateway_pods(%{gateway.id => "10.0.0.2"})
    stub_ingress_sends()

    parent = self()

    stub(RenderAccessDNS, :call, fn ->
      send(parent, :dns_render)
      :ok
    end)

    stub(RenderAccessDNS, :call, fn _opts ->
      send(parent, :dns_render)
      :ok
    end)

    assert {:ok, %{checked: 1, converged: 1}} = ReconcileAccessAdmission.call()
    assert drain_dns_renders() == 1
    drain_access_ingresses()

    # The pod moved: the memo differs, so the arms re-apply with the new
    # address and the views re-render — still exactly once per pass.
    stub_gateway_pods(%{gateway.id => "10.0.0.3"})

    assert {:ok, %{checked: 1, converged: 1}} = ReconcileAccessAdmission.call()
    assert drain_dns_renders() == 1

    created = drain_access_ingresses()
    moved = specs_in(created, instance.namespace)
    assert Enum.any?(moved, &(&1.source_ip == "10.0.0.3"))
    refute Enum.any?(moved, &(&1.source_ip == "10.0.0.2"))
  end

  test "no running pod converges on :none with the routes withheld; the next pass is a no-op",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    # No pod entry: the list comes back empty for this gateway.
    stub_gateway_pods(%{})

    parent = self()

    stub(Ingress, :delete, fn _kc, ns, name ->
      send(parent, {:access_route_deleted, ns, name})
      :ok
    end)

    assert {:ok, %{checked: 1, converged: 1}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(gateway.id) == :none

    deleted = drain_deletions()
    assert Enum.any?(deleted, fn {ns, _name} -> ns == instance.namespace end)

    # Still no pod, memo already :none: nothing re-runs.
    assert {:ok, %{checked: 1, converged: 0}} = ReconcileAccessAdmission.call()
    assert drain_deletions() == []
  end

  test "a failed pod read decides nothing: warning logged, memo untouched",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    stub_gateway_pods(%{gateway.id => {:error, :api_down}})

    log =
      capture_log(fn ->
        assert {:ok, %{checked: 1, converged: 0}} = ReconcileAccessAdmission.call()
      end)

    assert log =~ "address read failed"
    assert Activity.admitted_source(gateway.id) == nil
  end

  test "a failed re-apply leaves the memo :dirty; the next pass retries the whole set",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    stub_gateway_pods(%{gateway.id => "10.0.0.4"})

    # First apply fails, every later one succeeds — no shared state.
    expect(EdgeRoutes, :apply_access_for_status, 1, fn _kc, _gw, _i -> {:error, :boom} end)

    stub(EdgeRoutes, :apply_access_for_status, fn _kc, _gw, _i -> :ok end)

    assert {:ok, %{checked: 1, converged: 0}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(gateway.id) == :dirty

    # :dirty differs from the address, so the set retries — and holds.
    assert {:ok, %{checked: 1, converged: 1}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(gateway.id) == "10.0.0.4"
  end

  test "a status moving during the apply is re-applied in the fresh mode",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    stub_gateway_pods(%{gateway.id => "10.0.0.5"})

    parent = self()

    stub(EdgeRoutes, :apply_access_for_status, fn _kc, _gw, i ->
      send(parent, {:applied_status, i.status})

      # The sleep commits between the pass's read and its re-read.
      if i.status == :running, do: AccessFixtures.sleep!(i)

      :ok
    end)

    assert {:ok, %{checked: 1, converged: 1}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(gateway.id) == "10.0.0.5"
    assert drain_applied_statuses() == [:running, :sleeping]
  end

  test "a failed instance kubeconfig read fails the instance and leaves the memo :dirty",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    stub_gateway_pods(%{gateway.id => "10.0.0.8"})

    stub(InstanceK8s, :kubeconfig_for, fn _instance -> {:error, :cluster_gone} end)

    log =
      capture_log(fn ->
        assert {:ok, %{checked: 1, converged: 0}} = ReconcileAccessAdmission.call()
      end)

    assert log =~ "kubeconfig read failed"
    assert Activity.admitted_source(gateway.id) == :dirty
  end

  test "a fresh-status re-apply that fails leaves the memo :dirty",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    pair!(gateway, instance)

    stub_gateway_pods(%{gateway.id => "10.0.0.9"})

    log =
      capture_log(fn ->
        # The first apply (the :running row) succeeds and the sleep
        # commits under it; the re-read sees :sleeping and that fresh
        # re-apply fails.
        stub(EdgeRoutes, :apply_access_for_status, fn _kc, _gw, i ->
          if i.status == :running do
            AccessFixtures.sleep!(i)
            :ok
          else
            {:error, :boom}
          end
        end)

        assert {:ok, %{checked: 1, converged: 0}} = ReconcileAccessAdmission.call()
      end)

    assert log =~ "access re-apply failed"
    assert Activity.admitted_source(gateway.id) == :dirty
  end

  test "public and namespace-less pairings are skipped — only the private deployed instance re-arms",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    private = AccessFixtures.private_instance!(org, owner)
    public = AccessFixtures.public_instance!(org, owner)
    namespaceless = undeployed_private!(owner)

    pair!(gateway, private, "8443")
    pair!(gateway, public, "8444")
    pair!(gateway, namespaceless, "8445")

    stub_gateway_pods(%{gateway.id => "10.0.0.6"})

    parent = self()

    stub(EdgeRoutes, :apply_access_for_status, fn _kc, _gw, i ->
      send(parent, {:applied_instance, i.id})
      :ok
    end)

    assert {:ok, %{checked: 1, converged: 1}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(gateway.id) == "10.0.0.6"
    assert drain_applied_instances() == [private.id]
  end

  test "a :suspended gateway is covered and a :destroying gateway is skipped",
       %{org: org, owner: owner} do
    active = AccessFixtures.gateway!(org)
    active_instance = AccessFixtures.private_instance!(org, owner)
    pair!(active, active_instance)

    {suspended_org, suspended_owner} = funded_org!()
    suspended = AccessFixtures.gateway!(suspended_org, state: :suspended)
    suspended_instance = AccessFixtures.private_instance!(suspended_org, suspended_owner)
    pair!(suspended, suspended_instance)

    {destroying_org, destroying_owner} = funded_org!()
    destroying = AccessFixtures.gateway!(destroying_org, state: :destroying)
    destroying_instance = AccessFixtures.private_instance!(destroying_org, destroying_owner)
    pair!(destroying, destroying_instance)

    stub_ingress_sends()

    parent = self()

    stub(Ingress, :delete, fn _kc, ns, name ->
      send(parent, {:access_route_deleted, ns, name})
      :ok
    end)

    # The active gateway has a pod; the suspended one has none (its
    # routes are withheld, :none converges); the destroying one is not
    # examined at all.
    stub_gateway_pods(%{active.id => "10.0.0.7", destroying.id => "10.0.0.9"})

    assert {:ok, %{checked: 2, converged: 2}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(active.id) == "10.0.0.7"
    assert Activity.admitted_source(suspended.id) == :none
    assert Activity.admitted_source(destroying.id) == nil

    created = drain_access_ingresses()
    assert specs_in(created, active_instance.namespace) != []
    assert specs_in(created, destroying_instance.namespace) == []

    deleted = drain_deletions()
    assert Enum.any?(deleted, fn {ns, _name} -> ns == suspended_instance.namespace end)
    refute Enum.any?(deleted, fn {ns, _name} -> ns == destroying_instance.namespace end)
  end

  test "two organizations: each gateway's admitted source follows its own pod, end to end",
       %{org: org_a, owner: owner_a} do
    {org_b, owner_b} = funded_org!()

    gateway_a = AccessFixtures.gateway!(org_a)
    instance_a = AccessFixtures.private_instance!(org_a, owner_a)
    pair!(gateway_a, instance_a)

    gateway_b = AccessFixtures.gateway!(org_b)
    instance_b = AccessFixtures.private_instance!(org_b, owner_b)
    pair!(gateway_b, instance_b)

    stub_gateway_pods(%{gateway_a.id => "10.0.0.1", gateway_b.id => "10.0.0.2"})
    stub_ingress_sends()

    assert {:ok, %{checked: 2, converged: 2}} = ReconcileAccessAdmission.call()
    assert Activity.admitted_source(gateway_a.id) == "10.0.0.1"
    assert Activity.admitted_source(gateway_b.id) == "10.0.0.2"

    created = drain_access_ingresses()
    specs_a = specs_in(created, instance_a.namespace)
    specs_b = specs_in(created, instance_b.namespace)

    assert specs_a != []
    assert Enum.all?(specs_a, &(&1.source_ip == "10.0.0.1"))
    assert specs_b != []
    assert Enum.all?(specs_b, &(&1.source_ip == "10.0.0.2"))

    # Only B's pod moves: B re-mints with the new address, A sees
    # nothing new, and the pass reports one converged of two checked.
    stub_gateway_pods(%{gateway_a.id => "10.0.0.1", gateway_b.id => "10.0.0.22"})

    assert {:ok, %{checked: 2, converged: 1}} = ReconcileAccessAdmission.call()

    moved_created = drain_access_ingresses()
    assert specs_in(moved_created, instance_a.namespace) == []

    moved = specs_in(moved_created, instance_b.namespace)
    assert moved != []
    assert Enum.all?(moved, &(&1.source_ip == "10.0.0.22"))
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp funded_org! do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)
    {org, owner}
  end

  # The route_key is unique per gateway (the pairing's own identity),
  # so multi-instance tests hand each pairing its own.
  defp pair!(gateway, instance, route_key \\ "8443") do
    AccessRoute.create!(
      %{gateway_id: gateway.id, instance_id: instance.id, route_key: route_key},
      authorize?: false
    )
  end

  # Private exposure without a deploy: the pin's forced write is the
  # test seam for system-written fields, so the namespace-less skip arm
  # is observable on a genuinely private row.
  defp undeployed_private!(owner) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{
          name: "Undeployed #{System.unique_integer()}",
          app_version_id: version.id,
          env_vars: %{}
        },
        actor: owner
      )

    InstanceFixtures.pin!(instance, exposure: :private)
  end

  # Pods by the gateway label (the pass's and the arms' own read): a
  # binary value is one running pod at that address, an {:error, _}
  # tuple is a failed list, a missing key is an empty list.
  defp stub_gateway_pods(mapping) do
    stub(Pod, :list_by_labels, fn _kc, _ns, labels ->
      case Map.fetch(mapping, labels["fluxvale.io/gateway"]) do
        {:ok, ip} when is_binary(ip) -> {:ok, [gateway_pod(ip)]}
        {:ok, {:error, _reason} = error} -> error
        :error -> {:ok, []}
      end
    end)
  end

  defp gateway_pod(ip) do
    %{
      "metadata" => %{"creationTimestamp" => "2026-11-01T02:00:00Z"},
      "status" => %{"phase" => "Running", "podIP" => ip}
    }
  end

  defp stub_ingress_sends do
    parent = self()

    stub(Ingress, :create, fn _kc, ns, _name, spec ->
      send(parent, {:access_ingress, ns, spec})
      {:ok, %{}}
    end)
  end

  defp drain_access_ingresses(acc \\ []) do
    receive do
      {:access_ingress, ns, spec} -> drain_access_ingresses([{ns, spec} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_deletions(acc \\ []) do
    receive do
      {:access_route_deleted, ns, name} -> drain_deletions([{ns, name} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_dns_renders(count \\ 0) do
    receive do
      :dns_render -> drain_dns_renders(count + 1)
    after
      0 -> count
    end
  end

  defp drain_applied_statuses(acc \\ []) do
    receive do
      {:applied_status, status} -> drain_applied_statuses([status | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_applied_instances(acc \\ []) do
    receive do
      {:applied_instance, id} -> drain_applied_instances([id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp specs_in(created, namespace) do
    for {ns, spec} <- created, ns == namespace, do: spec
  end
end
