defmodule FluxVale.Workers.StrandedInstanceSweepTest do
  @moduledoc false

  # The cron entry point (#154): one sweep pass. The arms' own suite
  # covers the decisions; this covers the result plumbing.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.Workers.StrandedInstanceSweep

  setup do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Namespace, :list, fn _kc -> {:ok, []} end)
    stub_deletes()

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    {:ok, version: version}
  end

  test "perform/1 drives a stranded row to terminal and reports ok", %{version: version} do
    instance =
      Instance.create!(%{name: "Stranded", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    running = InstanceFixtures.walk_to!(instance, :running)

    {:ok, deleting} = InstanceK8s.update_status(running, :deleting, "Tearing down...")
    InstanceFixtures.pin!(deleting, namespace: "fluxvale-app-#{instance.id}")

    assert :ok = StrandedInstanceSweep.perform(%Oban.Job{})

    assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, authorize?: false)
  end

  test "perform/1 surfaces a failed pass for Oban to retry" do
    stub(Namespace, :list, fn _kc -> {:error, Error.connection_error("cluster down")} end)

    assert {:error, "stranded-instance sweep failed for 1 unit(s)"} =
             StrandedInstanceSweep.perform(%Oban.Job{})
  end

  defp user do
    User.create!("sweep-worker-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp stub_deletes do
    stub(Ingress, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Service, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Deployment, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Secret, :delete, fn _kc, _ns, _n -> :ok end)
    stub(PersistentVolumeClaim, :delete, fn _kc, _ns, _n -> :ok end)
    stub(NetworkPolicy, :delete, fn _kc, _ns, _n -> :ok end)
    stub(ResourceQuota, :delete, fn _kc, _ns, _n -> :ok end)
    stub(RoleBinding, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Namespace, :delete, fn _kc, _n -> :ok end)
  end
end
