defmodule FluxVale.Infrastructure.BackupRun.OutcomeMarkersTest do
  @moduledoc """
  The backup-outcome telemetry: one [:flux_vale, :backup, :run] per
  TERMINAL finalize (:succeeded/:failed reached from another status)
  with the run's kind and its started_at→finished_at duration — and
  nothing on the :running flip or a re-finalize over a settled row.

  `async: false`: the events ride the global telemetry handler table
  (the WakeMarkers test's stance).
  """

  use FluxVale.DataCase, async: false

  import Ash.Changeset

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.Telemetry

  @run_event [:flux_vale, :backup, :run]

  setup do
    Telemetry.capture_events([@run_event])

    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    {:ok, version: version}
  end

  test "a successful finalize emits kind/status and the wall-clock duration", %{version: version} do
    now = DateTime.utc_now(:second)
    started = DateTime.add(now, -10, :second)
    run = run!(version, %{kind: :scheduled, started_at: started})

    {:ok, done} =
      run
      |> for_update(:update, %{status: :running})
      |> Ash.update(authorize?: false)

    assert done.status == :running

    drain_events()

    finished_at = DateTime.utc_now(:second)

    {:ok, succeeded} =
      done
      |> for_update(:update, %{status: :succeeded, finished_at: finished_at})
      |> Ash.update(authorize?: false)

    assert succeeded.status == :succeeded

    assert_receive {:telemetry_event, @run_event, %{count: 1, duration: duration},
                    %{kind: :scheduled, status: :succeeded}}

    # started_at/finished_at are :utc_datetime (second precision), so
    # the truncation wobbles the true -10s by up to a second.
    assert duration >= 9.0 and duration <= 10.5
  end

  test "the apply-failure arm (fail_now's shape) emits :failed straight from :pending", %{
    version: version
  } do
    run = run!(version, %{kind: :manual})

    {:ok, failed} =
      run
      |> for_update(:update, %{
        status: :failed,
        error_summary: "backup job could not be applied",
        finished_at: DateTime.utc_now(:second)
      })
      |> Ash.update(authorize?: false)

    assert failed.status == :failed

    assert_receive {:telemetry_event, @run_event, %{count: 1, duration: _},
                    %{kind: :manual, status: :failed}}
  end

  test "a terminal finalize without finished_at reports duration 0.0 (defensive stamp)", %{
    version: version
  } do
    run = run!(version, %{kind: :restore, restored_from: :running})

    {:ok, failed} =
      run
      |> for_update(:update, %{status: :failed, error_summary: "job vanished"})
      |> Ash.update(authorize?: false)

    assert failed.status == :failed

    assert_receive {:telemetry_event, @run_event, %{count: 1, duration: 0.0},
                    %{kind: :restore, status: :failed}}
  end

  test "a re-finalize over a settled row is not a second backup", %{version: version} do
    run = run!(version, %{kind: :scheduled})

    {:ok, done} =
      run
      |> for_update(:update, %{
        status: :succeeded,
        snapshot_id: "6b757e02",
        finished_at: DateTime.utc_now(:second)
      })
      |> Ash.update(authorize?: false)

    assert done.status == :succeeded

    drain_events()

    # The sweep racing itself: the second write is refused by nothing
    # but contract (terminal never changes) — and even a same-status
    # rewrite must not count twice.
    {:ok, settled} =
      done
      |> for_update(:update, %{status: :succeeded})
      |> Ash.update(authorize?: false)

    assert settled.status == :succeeded

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end

  defp drain_events do
    receive do
      {:telemetry_event, _event, _measurements, _metadata} -> drain_events()
    after
      0 -> :ok
    end
  end

  defp run!(version, overrides) do
    owner =
      User.create!("outcome-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

    instance =
      Instance.create!(
        %{name: "Outcome #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    attrs =
      Map.merge(
        %{instance_id: instance.id, kind: :manual, started_at: DateTime.utc_now()},
        overrides
      )

    BackupRun
    |> for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end
end
