defmodule FluxVale.Infrastructure.Operations.SweepIdleInstancesTest do
  @moduledoc false

  # async: false — the threshold test mutates global app env; a
  # concurrent suite module would see the shortened clock.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.SweepIdleInstances
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("sweep-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp instance!(attrs) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "App", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    InstanceFixtures.pin!(instance,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  # The idle clock: a stale marker sleeps, a fresh one doesn't.
  defp with_marker!(instance, last_used_at) do
    instance
    |> InstanceFixtures.walk_to!(:running)
    |> InstanceFixtures.pin!(last_used_at: last_used_at)
  end

  defp stub_sleep_edge do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  setup do
    stub_sleep_edge()
    :ok
  end

  test "sleeps a running instance whose marker lapsed the threshold" do
    stale = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    created = instance!(%{})
    instance = with_marker!(created, stale)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert instance.id in summary.slept_ids

    slept = Instance.get_by_id!(instance.id, authorize?: false)
    assert slept.status == :sleeping
  end

  test "a fresh marker keeps the instance awake" do
    fresh = DateTime.add(DateTime.utc_now(), -60, :second)
    created = instance!(%{})
    instance = with_marker!(created, fresh)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert summary.slept_ids == []

    still_running = Instance.get_by_id!(instance.id, authorize?: false)
    assert still_running.status == :running
  end

  test "always_on rows never sleep — the scale-to-zero opt-out" do
    stale = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    created = instance!(%{})
    running = with_marker!(created, stale)

    {:ok, instance} = Instance.set_always_on(running, %{always_on: true}, authorize?: false)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert summary.slept_ids == []

    still_running = Instance.get_by_id!(instance.id, authorize?: false)
    assert still_running.status == :running
  end

  test "non-running rows are not candidates" do
    stale = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

    created = instance!(%{})
    running = with_marker!(created, stale)
    {:ok, _stopped} = Instance.stop(running, authorize?: false)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert summary.slept_ids == []
  end

  test "a seeded running row with no marker is skipped loudly (pre-backfill drift)" do
    created = instance!(%{})
    running = InstanceFixtures.walk_to!(created, :running)

    # The one shape the transitions can't produce — enter_running
    # always sets the marker; only pre-#203 drift leaves it nil. A
    # forced funnel write (the fixture's pin) stages it.
    drifted = InstanceFixtures.pin!(running, last_used_at: nil)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert drifted.id not in summary.slept_ids

    still_running = Instance.get_by_id!(drifted.id, authorize?: false)
    assert still_running.status == :running
  end

  test "a row that STOPPED between the batch read and its sleep is left alone" do
    stale = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    created = instance!(%{})
    running = with_marker!(created, stale)

    # The sweep's re-read must see this, not the batch snapshot.
    {:ok, _stopped} = Instance.stop(running, authorize?: false)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert summary.slept_ids == []

    kept = Instance.get_by_id!(created.id, authorize?: false)
    assert kept.status == :stopped
  end

  test "a visitor inside the read-to-sleep window keeps the instance awake" do
    stale = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    created = instance!(%{})
    _running = with_marker!(created, stale)

    # A fresh touch lands between the batch read and the re-read.
    {:ok, touched} = Instance.touch(_running, authorize?: false)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert summary.slept_ids == []

    kept = Instance.get_by_id!(touched.id, authorize?: false)
    assert kept.status == :running
  end

  test "the threshold is runtime config, not a compile-time promise" do
    # The E2E stack shortens the clock through this same knob.
    on_exit(fn -> Application.put_env(:flux_vale, :idle_sleep_after_seconds, 3600) end)
    Application.put_env(:flux_vale, :idle_sleep_after_seconds, 10)

    recent = DateTime.add(DateTime.utc_now(), -30, :second)
    created = instance!(%{})
    instance = with_marker!(created, recent)

    assert {:ok, summary} = SweepIdleInstances.call()
    assert instance.id in summary.slept_ids
  end
end
