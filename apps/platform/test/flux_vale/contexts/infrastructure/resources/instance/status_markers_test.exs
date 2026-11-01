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

    {:ok, errored} =
      InstanceK8s.update_status(starting, :error, "rollout failed", :rollout_failed)

    assert errored.status == :error
    assert errored.failure_reason == :rollout_failed

    assert_receive {:telemetry_event, @status_event, %{count: 1},
                    %{from: :starting, to: :error, reason: :rollout_failed}}
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
end
