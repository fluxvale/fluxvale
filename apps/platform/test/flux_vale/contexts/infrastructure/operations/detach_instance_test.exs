defmodule FluxVale.Infrastructure.Operations.DetachInstanceTest do
  @moduledoc false

  # The S2 hook (ADR-0040 §7): the provider's detach runs its own order
  # (policy → row → configs) and THEN the operation removes the access
  # edge — the IngressRoutes are the access edge's configs, so they go
  # last. The provider is stubbed; the assertion surface is the removal
  # and its order.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.DetachInstance
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

    # The S4 hook: a committed detach re-renders the resolver view
    # best-effort. Default success; expect-ed where a test cares.
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  test "detach removes the access routes and middleware AFTER the provider lands", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)
    ns = "fluxvale-app-#{instance.id}"

    AccessRoute.create!(
      %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
      authorize?: false
    )

    parent = self()

    stub(Tailscale, :detach_instance, fn _gateway, inst ->
      # The provider's own order: policy, row, serve config. The row is
      # the part this test's order pin reads.
      route = AccessRoute.get_by_instance!(inst.id, authorize?: false)
      AccessRoute.destroy!(route, authorize?: false)

      send(parent, {:provider_landed})
      :ok
    end)

    stub(Ingress, :delete, fn _kc, ^ns, "access-" <> _tail ->
      send(parent, {:access_route_removed})
      :ok
    end)

    stub(Middleware, :delete, fn _kc, ^ns, "fluxvale-access-wake" -> :ok end)

    assert :ok = DetachInstance.call(gateway, instance)

    # The mailbox order is the discipline: the reachability gate and
    # the pairing row close first; the access edge's configs go last.
    assert_received {:provider_landed}
    assert_received {:access_route_removed}
  end

  test "a provider failure returns it and never touches the access edge", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)

    expect(Tailscale, :detach_instance, fn _gateway, _instance -> {:error, :cluster_down} end)

    # No access-edge write may happen past a failed provider: the row
    # still exists to retry against (the provider's own order stance).
    reject(Ingress, :delete, 3)
    reject(Middleware, :delete, 3)

    assert {:error, :cluster_down} = DetachInstance.call(gateway, instance)
  end

  test "the removal is idempotent — missing objects are the posture", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)

    stub(Tailscale, :detach_instance, fn _gateway, _instance -> :ok end)

    stub(Ingress, :delete, fn _kc, _ns, _name ->
      {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
    end)

    stub(Middleware, :delete, fn _kc, _ns, _name ->
      {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
    end)

    assert :ok = DetachInstance.call(gateway, instance)
    assert :ok = DetachInstance.call(gateway, instance)
  end

  test "a cross-org detach is refused before anything runs", %{org: org} do
    {other_org, other_owner} = BillingFixtures.grant_free_org!()
    # Instance create's funded-wallet gate (#124) applies to this org too.
    {:ok, other_wallet} = FluxVale.Billing.ensure_wallet(other_org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(other_wallet, 10_000, reason: :adjustment)

    gateway = AccessFixtures.gateway!(org)
    # The instance belongs to the OTHER org entirely.
    instance = AccessFixtures.private_instance!(other_org, other_owner)

    # Nothing may run — not the provider, not the access edge.
    reject(K8s, :kubeconfig, 1)

    assert {:error, :different_organization} = DetachInstance.call(gateway, instance)
  end

  describe "the S4 render hook (ADR-0040 §4)" do
    test "a committed detach re-renders the resolver view", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      stub(Tailscale, :detach_instance, fn _gateway, _instance -> :ok end)

      # The access edge's removal: no hostname route / wake middleware
      # exists in this bare shape — the posture already holds.
      stub(Ingress, :delete, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(Middleware, :delete, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert :ok = DetachInstance.call(gateway, instance)
    end

    test "a failed edge removal never re-renders", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      stub(Tailscale, :detach_instance, fn _gateway, _instance -> :ok end)

      stub(Ingress, :delete, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      stub(RenderAccessDNS, :call, fn -> flunk("no render on a failed primary") end)
      stub(RenderAccessDNS, :call, fn _opts -> flunk("no render on a failed primary") end)

      assert {:error, _reason} = DetachInstance.call(gateway, instance)
    end
  end
end
