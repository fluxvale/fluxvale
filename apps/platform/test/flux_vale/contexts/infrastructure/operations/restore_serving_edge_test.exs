defmodule FluxVale.Infrastructure.Operations.RestoreServingEdgeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.RestoreServingEdge
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
end
