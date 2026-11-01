defmodule FluxVale.Workers.ZeroBalanceSweepTest do
  @moduledoc false

  # The cron entry point (#124): every wallet, one ladder pass each. The
  # ladder's own suite covers the decisions; this covers the iteration
  # and the fail-loud contract (one bad wallet fails the hour's job).

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
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

    # drain to ≤ 0 — the whole welcome balance, whatever it is
    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    {:ok, _debit} = Billing.debit_wallet(wallet, balance * 10_000)

    assert :ok = ZeroBalanceSweep.perform(%Oban.Job{})

    assert {:ok, still_running} = Instance.get_by_id(healthy_running.id, actor: healthy)
    assert still_running.status == :running

    assert {:ok, stopped} = Instance.get_by_id(broke_running.id, actor: broke)
    assert stopped.status == :stopped
  end

  test "failing wallets are skipped — error tuples and crashes both — the job still fails" do
    # Note: the grant-free owner's JIT org carries its own welcome wallet —
    # more wallets than the ones under test; the stub is shape-based, and
    # the call log (not a call count) proves the good one ran.
    {good_org, _owner} = BillingFixtures.funded_wallet!()
    {bad_org, _owner2} = BillingFixtures.grant_free_org!()
    {:ok, bad_wallet} = Billing.ensure_wallet(bad_org)
    {crash_org, _owner3} = BillingFixtures.grant_free_org!()
    {:ok, crash_wallet} = Billing.ensure_wallet(crash_org)

    summary = %FluxVale.Billing.Operations.SweepZeroBalance{
      runway_warning_sent: false,
      destroy_warning: nil,
      stopped_ids: [],
      destroyed_ids: [],
      suspended_gateway_ids: [],
      suspended_domain_ids: []
    }

    stub(Billing, :sweep_zero_balance, fn
      %{id: id} when id == bad_wallet.id -> {:error, :boom}
      %{id: id} when id == crash_wallet.id -> raise "kaboom"
      _wallet -> {:ok, summary}
    end)

    assert {:error, "zero-balance sweep failed for 2 wallet(s)"} =
             ZeroBalanceSweep.perform(%Oban.Job{})

    # isolation, not abort-on-first: every wallet got its pass
    sweeps = Mimic.calls(&FluxVale.Billing.sweep_zero_balance/1)
    swept_ids = Enum.map(sweeps, fn [wallet] -> wallet.id end)

    {:ok, good_wallet} = Wallet.get_by_organization(good_org.id, authorize?: false)

    assert good_wallet.id in swept_ids
    assert bad_wallet.id in swept_ids
    assert crash_wallet.id in swept_ids
  end

  defp walk_to_running!(instance) do
    Enum.reduce([:deploying, :starting, :running], instance, fn status, acc ->
      {:ok, next} = InstanceK8s.update_status(acc, status, nil)
      next
    end)
  end
end
