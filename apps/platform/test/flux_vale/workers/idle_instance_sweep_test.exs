defmodule FluxVale.Workers.IdleInstanceSweepTest do
  @moduledoc false

  # The cron entry point (#203): one idle-sweep pass. The sweep's own
  # suite covers the decisions; this covers the result plumbing.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.Workers.IdleInstanceSweep

  setup do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    {:ok, version: version}
  end

  test "perform/1 sleeps an idle instance and reports ok", %{version: version} do
    instance =
      Instance.create!(%{name: "Idle", app_version_id: version.id, env_vars: %{}}, actor: user())

    running = InstanceFixtures.walk_to!(instance, :running)

    stale = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{instance.id}", last_used_at: stale)

    assert :ok = IdleInstanceSweep.perform(%Oban.Job{})

    slept = Instance.get_by_id!(instance.id, authorize?: false)
    assert slept.status == :sleeping
  end

  test "perform/1 surfaces a failed pass for Oban to retry" do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(%{name: "Broken", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    running = InstanceFixtures.walk_to!(instance, :running)

    stale = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{instance.id}", last_used_at: stale)

    # A raising arm (an unexpected crash, not a K8s error tuple) is
    # the sweep's rescue path — the worker's error surface.
    expect(Deployment, :scale, fn _kc, _ns, _n, _r ->
      raise "k8s api exploded"
    end)

    assert {:error, "idle-instance sweep failed for 1 unit(s)"} =
             IdleInstanceSweep.perform(%Oban.Job{})
  end

  defp user do
    User.create!("idle-worker-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end
end
