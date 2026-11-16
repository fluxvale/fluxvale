defmodule FluxVale.Infrastructure.Instance.StatusMarkersTest do
  @moduledoc """
  The lifecycle funnel's outcome telemetry: one
  [:flux_vale, :instance, :status_transition] per REAL transition —
  labeled by the state machine's closed enums, never by fleet size —
  and nothing on the funnel's legal same-status no-op.

  `async: false`: the events ride the global telemetry handler table —
  a concurrent module's lifecycle writes would bleed into these
  assertions (the WakeMarkers test's stance).
  """

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
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
  alias FluxVale.TestSupport.Telemetry

  @status_event [:flux_vale, :instance, :status_transition]

  setup do
    Telemetry.capture_events([@status_event])

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    {:ok, version: version}
  end

  test "a real transition emits from/to with reason nil off :error", %{version: version} do
    instance = instance!(version)

    {:ok, deploying} = InstanceK8s.update_status(instance, :deploying, "Deploying to Kubernetes…")

    assert deploying.status == :deploying

    assert_receive {:telemetry_event, @status_event, %{count: 1},
                    %{from: :pending, to: :deploying, reason: nil}}
  end

  test "an :error write carries the failure_reason from the produced record", %{
    version: version
  } do
    instance = instance!(version)
    starting = InstanceFixtures.walk_to!(instance, :starting)
    drain_events()

    errored_at_wall = DateTime.utc_now()

    {:ok, errored} =
      InstanceK8s.update_status(starting, :error, "rollout failed", :rollout_failed)

    assert errored.status == :error
    assert errored.failure_reason == :rollout_failed

    assert_receive {:telemetry_event, @status_event, %{count: 1},
                    %{from: :starting, to: :error, reason: :rollout_failed}}

    # #182: the entering write stamps errored_at — the gauge's recency
    # clock, one changeset with the counter emission.
    assert DateTime.diff(errored.errored_at, errored_at_wall, :second) in -1..1
  end

  # The reconcile no-op guarantee (#182): a same-status write bumps
  # updated_at but must NOT refresh errored_at — the stamp is the
  # episode's entry instant, and refreshing it would make a
  # long-deadlocked row (the #818 memos shape, no-op'd every minute)
  # look freshly stuck forever.
  test "a same-status write never refreshes errored_at", %{version: version} do
    instance = instance!(version)
    starting = InstanceFixtures.walk_to!(instance, :starting)

    {:ok, errored} = InstanceK8s.update_status(starting, :error, "rollout failed")
    drain_events()

    {:ok, still} = InstanceK8s.update_status(errored, :error, "still failing")

    assert still.errored_at == errored.errored_at
  end

  test "a same-status write (the funnel's message-only no-op) emits nothing", %{
    version: version
  } do
    instance = instance!(version)
    running = InstanceFixtures.walk_to!(instance, :running)
    drain_events()

    {:ok, still} = InstanceK8s.update_status(running, :running, "still up")

    assert still.status == :running

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end

  # The crash-edge ENTRY the error-occupancy alert pages on: a deploy
  # job that died bypassing the funnel. The handler's force-change is
  # a change-time write ahead of the mount, so the change-time read
  # sees :error (the ordering the moduledoc pins).
  test "mark_deploy_error emits the crash edge with the handler's reason", %{version: version} do
    created = instance!(version)

    deploying =
      created
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-marker",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(:deploying)

    drain_events()

    {:ok, errored} =
      deploying
      |> Ash.Changeset.for_update(:mark_deploy_error, %{error: %{}}, authorize?: false)
      |> Ash.update()

    assert errored.status == :error
    assert errored.failure_reason == :deploy_failed
    # #182: the mount order is pinned — the handler's force-change runs
    # ahead of StatusMarkers, so the entry stamp lands (an inverted
    # mount would read :deploying and skip it).
    assert %DateTime{} = errored.errored_at

    assert_receive {:telemetry_event, @status_event, %{count: 1},
                    %{from: :deploying, to: :error, reason: :deploy_failed}}
  end

  test "mark_teardown_error emits the same crash-edge shape", %{version: version} do
    created = instance!(version)

    running =
      created
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-marker",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(:running)

    {:ok, deleting} = InstanceK8s.update_status(running, :deleting, "Tearing down")
    drain_events()

    {:ok, errored} =
      deleting
      |> Ash.Changeset.for_update(:mark_teardown_error, %{error: %{}}, authorize?: false)
      |> Ash.update()

    assert errored.status == :error
    assert errored.failure_reason == :teardown_failed
    # #182: the entry stamp lands through the handler mount too.
    assert %DateTime{} = errored.errored_at

    assert_receive {:telemetry_event, @status_event, %{count: 1},
                    %{from: :deleting, to: :error, reason: :teardown_failed}}
  end

  # The EXIT the alert releases on: the owner's re-deploy. The :deploy
  # action's force-change is change-time too, and the inline trigger
  # then writes :starting through the funnel (a second, funnel-owned
  # event asserted below).
  test "deploy from :error emits the :error exit (then :starting via the funnel)", %{
    version: version
  } do
    stub_deploy_k8s()

    created = instance!(version)

    starting =
      created
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-marker",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(:starting)

    {:ok, errored} = InstanceK8s.update_status(starting, :error, "rollout failed")
    drain_events()

    {:ok, deploying} = Instance.deploy(errored, authorize?: false)

    assert deploying.status == :deploying
    # #182: the leaving write clears the gauge's clock — an exited
    # episode is not stuck, whatever its stamp said.
    assert is_nil(deploying.errored_at)

    assert_receive {:telemetry_event, @status_event, %{count: 1},
                    %{from: :error, to: :deploying, reason: nil}}

    # :inline runs the trigger during the action — its :starting write
    # rides the funnel and emits its own event.
    assert_receive {:telemetry_event, @status_event, %{count: 1},
                    %{from: :deploying, to: :starting, reason: nil}}
  end

  # walk_to! itself rides the funnel, so its steps land in the test's
  # mailbox — drain them before the write under assertion.
  defp drain_events do
    receive do
      {:telemetry_event, _event, _measurements, _metadata} -> drain_events()
    after
      0 -> :ok
    end
  end

  defp instance!(version) do
    Instance.create!(
      %{name: "Markers #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
      actor:
        User.create!("markers-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
    )
  end

  # The inline deploy trigger's cluster applies (instance_test's
  # stub_k8s, create side only — this suite never tears down).
  defp stub_deploy_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _data -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
  end
end
