defmodule FluxVale.Workers.ZeroBalanceSweepTest do
  @moduledoc false

  # The cron entry point (#124): every wallet, one ladder pass each. The
  # ladder's own suite covers the decisions; this covers the iteration
  # and the fail-loud contract (one bad wallet fails the hour's job).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.Workers.ZeroBalanceSweep

  setup do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, 0 -> {:ok, %{}} end)
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    {:ok, version: version}
  end

  test "perform/1 sweeps every wallet — the overdrawn one stops, the healthy one doesn't", %{
    version: version
  } do
    healthy = AccountsFixtures.user!()

    healthy_instance =
      Instance.create!(%{name: "Fine", app_version_id: version.id, env_vars: %{}}, actor: healthy)

    healthy_running = walk_to_running!(healthy_instance)

    broke = AccountsFixtures.user!()

    broke_instance =
      Instance.create!(%{name: "Broke", app_version_id: version.id, env_vars: %{}}, actor: broke)

    broke_running = walk_to_running!(broke_instance)

    org = AccountsFixtures.personal_org!(broke)
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, _debit} = Billing.debit_wallet(wallet, 10_000 * 10_000)

    assert :ok = ZeroBalanceSweep.perform(%Oban.Job{})

    assert {:ok, still_running} = Instance.get_by_id(healthy_running.id, actor: healthy)
    assert still_running.status == :running

    assert {:ok, stopped} = Instance.get_by_id(broke_running.id, actor: broke)
    assert stopped.status == :stopped
  end

  defp walk_to_running!(instance) do
    Enum.reduce([:deploying, :starting, :running], instance, fn status, acc ->
      {:ok, next} = InstanceK8s.update_status(acc, status, nil)
      next
    end)
  end
end
