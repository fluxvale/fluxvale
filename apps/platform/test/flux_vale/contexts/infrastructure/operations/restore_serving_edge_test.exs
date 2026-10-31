defmodule FluxVale.Infrastructure.Operations.RestoreServingEdgeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.RestoreServingEdge
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("restore-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp running_instance! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

    instance
    |> InstanceFixtures.pin!(
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
    |> InstanceFixtures.walk_to!(:running)
  end

  test "re-applies the serving routes — app target, beacon attached" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    instance = running_instance!()
    ns = "fluxvale-app-#{instance.id}"

    expect(Middleware, :create, fn _kc, ^ns, "fluxvale-activity", _spec -> {:ok, %{}} end)

    expect(Ingress, :create, fn _kc, ^ns, "app-ingress", spec ->
      assert spec.service_name == "app"
      assert spec.middlewares == ["fluxvale-activity"]
      {:ok, %{}}
    end)

    assert :ok = RestoreServingEdge.call(instance)
  end

  test "a cluster failure propagates — the wake endpoint serves the retry hint" do
    stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("cluster down")} end)
    instance = running_instance!()

    assert {:error, _error} = RestoreServingEdge.call(instance)
  end

  # #265: the self-healing flip must not mint a route the row says must
  # not exist — a crafted wake-marker naming a private instance gets
  # the no-op, not a public route (:ok with zero cluster calls).
  test "a private instance restores nothing — no route is ever minted for it" do
    instance = running_instance!()
    private = InstanceFixtures.pin!(instance, exposure: :private)

    reject(K8s, :kubeconfig, 1)
    reject(Ingress, :create, 4)

    assert :ok = RestoreServingEdge.call(private)
  end

  # ADR-0040 S2: the restore is the PUBLIC edge's self-healing flip. A
  # private+attached instance's access arms are NOT its business — the
  # wake endpoint's own flip owns them — so a restore must not
  # resurrect them (the private no-op stance, access-flavored).
  test "a private attached instance's restore resurrects no access arms" do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    InstanceFixtures.local_cluster!()

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)

    AccessRoute.create!(
      %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
      authorize?: false
    )

    # The private no-op stands even with a pairing row: no kubeconfig,
    # no route of any entrypoint (the wake endpoint's flip owns the
    # access arms — this call must stay a no-op).
    reject(K8s, :kubeconfig, 1)
    reject(Ingress, :create, 4)
    reject(Middleware, :create, 4)

    assert :ok = RestoreServingEdge.call(instance)
  end
end
