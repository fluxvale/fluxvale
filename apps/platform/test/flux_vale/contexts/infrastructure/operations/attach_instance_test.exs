defmodule FluxVale.Infrastructure.Operations.AttachInstanceTest do
  @moduledoc false

  # The S2 hook (ADR-0040 §7): the provider lands the pairing, then the
  # operation lands the ACCESS EDGE — the arms per the instance's status
  # and the widened policy — and a failed edge unwinds the row (a row
  # whose limbs never landed claims a pairing nothing can reach). The
  # provider is stubbed; the assertion surface is the access applies.

  use FluxVale.DataCase, async: true
  use Mimic

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

  defp gateway_pod_labels(gateway), do: InstanceK8s.gateway_pod_labels(gateway.id)

  # A private instance at :sleeping — the funnel's own write from
  # :running (AccessFixtures.sleep!/1).
  defp private_at!(org, owner) do
    org
    |> then(&AccessFixtures.private_instance!(&1, owner))
    |> AccessFixtures.sleep!()
  end
end
