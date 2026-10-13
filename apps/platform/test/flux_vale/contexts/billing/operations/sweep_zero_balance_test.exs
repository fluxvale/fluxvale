defmodule FluxVale.Billing.Operations.SweepZeroBalanceTest do
  @moduledoc false

  # The full ladder (#124's exit criteria): gate-adjacent runway warning
  # → auto-stop at ≤ 0 → destroy window T-7/T-1/destroy → recovery.
  # K8s is Mimic-stubbed (scale-to-zero for the stop, deletes for the
  # teardown); Oban runs :inline so the teardown completes in-test.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    {:ok, version: version}
  end

  # The org starts fixture-funded (10_000¢ welcome grant) — the deploy
  # gate needs it for the instance creation below; `adjust_to!` then
  # lands the exact target (posting never checks balance, so drains
  # overshoot freely).
  defp org! do
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)
    {user, wallet}
  end

  defp adjust_to!(wallet, balance_cents) do
    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    drift = balance - balance_cents

    cond do
      drift == 0 ->
        :ok

      drift > 0 ->
        {:ok, _debit} = Billing.debit_wallet(wallet, drift * 10_000)
        :ok

      true ->
        {:ok, _grant} = Billing.grant_credits(wallet, -drift)
        :ok
    end

    wallet
  end

  defp instance!(user, status, version) do
    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    chain = %{
      running: [:deploying, :starting, :running],
      stopped: [:deploying, :starting, :running, :stopped]
    }

    path = Map.fetch!(chain, status)

    reached =
      Enum.reduce(path, instance, fn status, acc ->
        {:ok, updated} = InstanceK8s.update_status(acc, status, nil)
        updated
      end)

    InstanceFixtures.pin!(reached, namespace: "fluxvale-app-#{instance.id}")
  end

  defp stub_stop do
    stub(Deployment, :scale, fn _kc, _ns, _name, 0 -> {:ok, %{}} end)
  end

  defp stub_teardown do
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

  defp reload_wallet!(wallet) do
    result = Wallet.get_by_organization(wallet.organization_id, authorize?: false)
    elem(result, 1)
  end

  defp backdate!(wallet, attrs) do
    wallet
    |> Ash.Changeset.for_update(:set_ladder_state, attrs, authorize?: false)
    |> Ash.update!()
  end

  describe "the healthy path" do
    test "a funded wallet with runway warns nothing, stops nothing", %{version: version} do
      {user, wallet} = org!()
      instance!(user, :running, version)
      adjust_to!(wallet, 1_000)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)
      refute summary.runway_warning_sent
      assert summary.stopped_ids == []
      assert summary.destroyed_ids == []

      refute_received {:email, _email}

      fresh = reload_wallet!(wallet)
      assert fresh.low_balance_warned_at == nil
      assert fresh.negative_since == nil
    end
  end

  describe "the runway warning" do
    test "runway < 24h warns once per episode, re-armed on recovery", %{version: version} do
      # 1¢ balance against a 100¢/mo instance → ~7h of runway
      {user, wallet} = org!()
      instance!(user, :running, version)
      adjust_to!(wallet, 1)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)
      assert summary.runway_warning_sent

      assert_received {:email, %Swoosh.Email{subject: "Your FluxVale balance is running low"}}

      # once per episode — the second sweep stays quiet
      assert {:ok, summary2} = Billing.sweep_zero_balance(wallet)
      refute summary2.runway_warning_sent
      refute_received {:email, _email}

      # top-up re-arms
      {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
      assert {:ok, _sweep} = Billing.sweep_zero_balance(wallet)
      assert reload_wallet!(wallet).low_balance_warned_at == nil
    end

    test "the warning body carries the rounded runway hours", %{version: version} do
      {user, wallet} = org!()
      instance!(user, :running, version)
      adjust_to!(wallet, 1)

      assert {:ok, _summary} = Billing.sweep_zero_balance(wallet)

      assert_received {:email, %Swoosh.Email{text_body: body}}
      assert body =~ "about 7 hours"
    end
  end

  describe "the auto-stop" do
    test "balance ≤ 0 stops running instances; non-running rows skip", %{version: version} do
      stub_stop()
      {user, wallet} = org!()
      running = instance!(user, :running, version)

      pending =
        Instance.create!(%{name: "P", app_version_id: version.id, env_vars: %{}}, actor: user)

      adjust_to!(wallet, 0)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)
      assert summary.stopped_ids == [running.id]

      assert {:ok, stopped} = Instance.get_by_id(running.id, actor: user)
      assert stopped.status == :stopped

      # the pending row was fed through stop's guard and skipped
      assert {:ok, still_pending} = Instance.get_by_id(pending.id, actor: user)
      assert still_pending.status == :pending
    end

    test "the stop reverses on top-up — start's gate reopens at balance > 0", %{
      version: version
    } do
      stub_stop()

      stub(Deployment, :scale, fn
        _kc, _ns, _name, 0 -> {:ok, %{}}
        _kc, _ns, _name, 1 -> {:ok, %{}}
      end)

      {user, wallet} = org!()
      instance = instance!(user, :running, version)
      adjust_to!(wallet, 0)

      assert {:ok, _summary} = Billing.sweep_zero_balance(wallet)

      {:ok, stopped} = Instance.get_by_id(instance.id, actor: user)
      assert stopped.status == :stopped

      # still broke — the gate holds
      assert {:error, %Ash.Error.Forbidden{}} = Instance.start(stopped, actor: user)

      # funded — start goes through
      {:ok, _grant} = Billing.grant_credits(wallet, 1_000)
      assert {:ok, starting} = Instance.start(stopped, actor: user)
      assert starting.status == :starting
    end
  end

  describe "the destroy window" do
    test "negative anchors the clock; T-7 then T-1 fire once each", %{version: version} do
      stub_stop()
      {user, wallet} = org!()
      instance!(user, :running, version)
      adjust_to!(wallet, -1)

      # first sighting: anchor + stop + the overdrawn low-balance
      # warning (a spent balance still gets its heads-up) — no destroy mail
      assert {:ok, sweep1} = Billing.sweep_zero_balance(wallet)
      assert sweep1.destroyed_ids == []
      assert sweep1.destroy_warning == nil
      assert sweep1.runway_warning_sent
      assert reload_wallet!(wallet).negative_since != nil

      assert_received {:email, %Swoosh.Email{subject: "Your FluxVale balance is running low"}}

      # 23 days in: T-7
      anchored_at = reload_wallet!(wallet).negative_since
      backdate!(reload_wallet!(wallet), negative_since: DateTime.add(anchored_at, -23, :day))

      assert {:ok, sweep2} = Billing.sweep_zero_balance(wallet)
      assert sweep2.destroy_warning == :t7

      assert_received {:email,
                       %Swoosh.Email{subject: "Your FluxVale instances will be deleted in 7 days"}}

      # t7 once
      assert {:ok, sweep2b} = Billing.sweep_zero_balance(wallet)
      assert sweep2b.destroy_warning == nil
      refute_received {:email, _email}

      # 29 days in: T-1
      backdate!(reload_wallet!(wallet), negative_since: DateTime.add(anchored_at, -29, :day))

      assert {:ok, sweep3} = Billing.sweep_zero_balance(wallet)
      assert sweep3.destroy_warning == :t1

      assert_received {:email,
                       %Swoosh.Email{subject: "Your FluxVale instances will be deleted in 1 day"}}
    end

    test "destroy at +30d tears every instance down, storage freed", %{version: version} do
      stub_stop()
      stub_teardown()
      {user, wallet} = org!()
      instance!(user, :running, version)
      adjust_to!(wallet, -1)

      {:ok, _sweep} = Billing.sweep_zero_balance(wallet)

      assert_received {:email, %Swoosh.Email{subject: "Your FluxVale balance is running low"}}

      anchored_at = reload_wallet!(wallet).negative_since
      thirty_days_ago = DateTime.add(anchored_at, -30, :day)
      backdate!(reload_wallet!(wallet), negative_since: thirty_days_ago)

      assert {:ok, sweep} = Billing.sweep_zero_balance(wallet)
      assert length(sweep.destroyed_ids) == 1

      # the row is gone — teardown's inline hard delete
      destroyed_id = hd(sweep.destroyed_ids)
      assert {:error, _not_found} = Instance.get_by_id(destroyed_id, actor: user)

      # the anchor survives (no re-armed 30-day cycle for the dead org):
      # a later sweep re-enters the destroy arm as a no-op, mail-less
      assert {:ok, later} = Billing.sweep_zero_balance(wallet)
      assert later.destroyed_ids == []
      assert later.destroy_warning == nil
      refute_received {:email, _email}
    end

    test "a top-up inside the window clears clock and markers", %{version: version} do
      stub_stop()
      {user, wallet} = org!()
      instance!(user, :running, version)
      adjust_to!(wallet, -1)

      {:ok, _sweep} = Billing.sweep_zero_balance(wallet)
      anchored_at = reload_wallet!(wallet).negative_since
      backdate!(reload_wallet!(wallet), negative_since: DateTime.add(anchored_at, -25, :day))

      # recovery mid-window
      {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
      assert {:ok, _sweep} = Billing.sweep_zero_balance(wallet)

      fresh = reload_wallet!(wallet)
      assert fresh.negative_since == nil
      assert fresh.destroy_t7_warned_at == nil
    end
  end

  describe "the parked-at-zero edge" do
    test "balance exactly 0 never anchors the destroy clock", %{version: version} do
      {user, wallet} = org!()
      instance!(user, :stopped, version)
      adjust_to!(wallet, 0)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)
      assert summary.destroyed_ids == []
      assert reload_wallet!(wallet).negative_since == nil
    end
  end
end
