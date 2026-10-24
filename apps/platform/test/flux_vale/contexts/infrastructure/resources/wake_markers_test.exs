defmodule FluxVale.Infrastructure.Instance.WakeMarkersTest do
  @moduledoc """
  #232's wake-latency instrumentation through the real funnel: the
  clocks the transitions keep, and the three telemetry events with
  sane values — the issue's "a spec asserts the Telemetry events fire
  with sane values on a wake in the test env".

  K8s applies/reads are Mimic-stubbed (the funnel itself is what's
  under test); `app` — the catalog slug — is the events' only label.
  `async: false`: the events ride the global telemetry handler table —
  a concurrent module's wake would bleed into these assertions (and
  Mimic is per-process anyway).
  """

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ReconcileInstance
  alias FluxVale.Infrastructure.Operations.WakeInstance
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.Telemetry

  @wake_events [
    [:flux_vale, :wake, :promotion],
    [:flux_vale, :wake, :boot],
    [:flux_vale, :wake, :total]
  ]

  # The whole 0-300s band is sane (a real wake is seconds-to-a-minute;
  # the bound only catches unit errors like a microsecond leak).
  @sane_min 0.0
  @sane_max 300.0

  setup do
    Telemetry.capture_events(@wake_events)
    :ok
  end

  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
  end

  defp stub_ready do
    stub(Deployment, :status, fn _kc, _ns, _n ->
      {:ok, %{replicas: 1, ready: 1, conditions: []}}
    end)
  end

  defp instance!(slug, target) do
    version = InstanceFixtures.app_version!(%{app_slug: slug})
    InstanceFixtures.local_cluster!()

    created =
      Instance.create!(
        %{name: "Wake", app_version_id: version.id, env_vars: %{}},
        actor:
          User.create!("wake-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      )

    created
    |> InstanceFixtures.pin!(
      namespace: "fluxvale-app-#{created.id}",
      deployed_at: DateTime.utc_now()
    )
    |> InstanceFixtures.walk_to!(target)
  end

  defp awaiting_event!(event) do
    receive do
      {:telemetry_event, ^event, measurements, metadata} -> {measurements, metadata}
    after
      1_000 -> flunk("expected #{inspect(event)} to fire")
    end
  end

  test "a wake fires all three events with sane values, then clears the clocks" do
    stub_k8s()
    stub_ready()
    instance = instance!("kavita-shaped", :sleeping)

    {:ok, waking} = WakeInstance.call(instance)

    assert waking.status == :starting
    assert waking.wake_requested_at
    assert waking.wake_promoted_at

    {%{duration: promotion}, %{app: app}} = awaiting_event!([:flux_vale, :wake, :promotion])
    assert app == "kavita-shaped"
    assert promotion >= @sane_min and promotion <= @sane_max

    {:ok, running} = ReconcileInstance.call(waking)

    assert running.status == :running
    assert is_nil(running.wake_requested_at)
    assert is_nil(running.wake_promoted_at)

    {%{duration: boot}, %{app: boot_app}} = awaiting_event!([:flux_vale, :wake, :boot])
    {%{duration: total}, %{app: total_app}} = awaiting_event!([:flux_vale, :wake, :total])

    assert boot_app == "kavita-shaped"
    assert total_app == "kavita-shaped"
    assert boot >= @sane_min and boot <= @sane_max
    assert total >= @sane_min and total <= @sane_max
    assert total >= promotion
  end

  test "a plain start from :stopped is not a wake — no clocks, no events" do
    stub_k8s()
    instance = instance!("plain-start", :stopped)

    {:ok, starting} = Instance.start(instance, authorize?: false)

    assert starting.status == :starting
    assert is_nil(starting.wake_requested_at)
    assert is_nil(starting.wake_promoted_at)

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end

  test "a wake whose scale fails lands :error with the clocks cleared", %{test: test} do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Deployment, :scale, fn _kc, _ns, _n, _r ->
      {:error, Error.connection_error("#{test}: scale refused")}
    end)

    instance = instance!("dies-mid-wake", :sleeping)

    {:ok, errored} = WakeInstance.call(instance)

    assert errored.status == :error
    assert is_nil(errored.wake_requested_at)
    assert is_nil(errored.wake_promoted_at)
  end

  test "the sleep sweep clears clocks a stale row carried in" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    running = instance!("resleeps", :running)
    stale = stamp_stale_clocks!(running)

    {:ok, reslept} = Instance.sleep(stale, authorize?: false)

    assert reslept.status == :sleeping
    assert is_nil(reslept.wake_requested_at)
    assert is_nil(reslept.wake_promoted_at)
  end

  # pin! rides the no-op same-status write StatusTransition allows.
  defp stamp_stale_clocks!(instance) do
    now = DateTime.utc_now()
    InstanceFixtures.pin!(instance, wake_requested_at: now, wake_promoted_at: now)
  end
end
