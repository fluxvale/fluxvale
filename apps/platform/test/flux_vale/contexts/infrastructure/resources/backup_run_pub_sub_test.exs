defmodule FluxVale.Infrastructure.BackupRunPubSubTest do
  @moduledoc false

  # #222's liveness contract: a run's writes publish on the INSTANCE's
  # topic — the one the instance page already subscribes to. A backup's
  # outcome never touches `Instance.status` (ADR-0037's consequences), so
  # without these publishes the backups panel would show a run as running
  # until the next page load.

  use FluxVale.DataCase, async: true

  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup do
    user = SessionHelpers.user!()
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    pending = InstanceFixtures.instance!(version, user)
    instance = InstanceFixtures.pin!(pending, namespace: "fluxvale-app-instance")

    {:ok, instance: instance}
  end

  test "create publishes on instances:<instance_id>", %{instance: instance} do
    Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

    changeset =
      Ash.Changeset.for_create(
        BackupRun,
        :create,
        %{instance_id: instance.id, kind: :manual, started_at: DateTime.utc_now()},
        authorize?: false
      )

    {:ok, run} = Ash.create(changeset)

    assert_receive %Ash.Notifier.Notification{
      resource: BackupRun,
      action: %{name: :create},
      data: notified
    }

    assert notified.id == run.id
    assert notified.status == :pending
  end

  test "update publishes on instances:<instance_id>", %{instance: instance} do
    changeset =
      Ash.Changeset.for_create(
        BackupRun,
        :create,
        %{instance_id: instance.id, kind: :scheduled, started_at: DateTime.utc_now()},
        authorize?: false
      )

    {:ok, run} = Ash.create(changeset)

    Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

    {:ok, finished} =
      run
      |> Ash.Changeset.for_update(
        :update,
        %{status: :succeeded, snapshot_id: "6b757e02", bytes_added: 42},
        authorize?: false
      )
      |> Ash.update()

    assert_receive %Ash.Notifier.Notification{
      resource: BackupRun,
      action: %{name: :update},
      data: notified
    }

    assert notified.id == finished.id
    assert notified.status == :succeeded
  end
end
