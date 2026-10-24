defmodule FluxVale.Workers.BackupSweepTest do
  @moduledoc false

  # The cron entry point (#222): one backup-sweep pass. The sweep's own
  # suite covers the decisions; this covers the result plumbing. Both
  # tests drive the watch pass, not the due pass: the worker hands the
  # operation `DateTime.utc_now/0`, so a due assertion here would only
  # hold after 03:00 UTC — the due arithmetic is pinned with fixed clocks
  # in sweep_backups_test.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.Workers.BackupSweep

  defp user do
    User.create!("backup-worker-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp active_run! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "Worker #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    pinned = InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")

    BackupSetting
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: pinned.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        access_key_id: "AKIAIOSFODNN7EXAMPLE"
      },
      authorize?: false
    )
    |> Ash.create!()

    # Started just now: well inside the stale horizon, so the watch pass
    # decides on the Job's status alone.
    BackupRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: pinned.id,
        kind: :manual,
        status: :running,
        started_at: DateTime.utc_now()
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  test "perform/1 runs a watch pass and reports ok" do
    run = active_run!()

    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(BackupJob, :status, fn _kc, _ns ->
      {:ok,
       %{
         outcome: :succeeded,
         message: ~s({"snapshot_id":"abc123","bytes_processed":10,"bytes_added":5}),
         exit_code: 0,
         reason: "Completed"
       }}
    end)

    assert :ok = BackupSweep.perform(%Oban.Job{})

    finished = Ash.get!(BackupRun, run.id, authorize?: false)
    assert finished.status == :succeeded
    assert finished.snapshot_id == "abc123"
  end

  test "perform/1 surfaces a failed pass for Oban to retry" do
    run = active_run!()

    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    # A raising arm (an unexpected crash, not a K8s error tuple) is the
    # sweep's rescue path — the worker's error surface.
    expect(BackupJob, :status, fn _kc, _ns ->
      {:error, Error.connection_error("k8s api exploded")}
    end)

    assert {:error, "backup sweep failed for 1 unit(s)"} = BackupSweep.perform(%Oban.Job{})

    assert Ash.get!(BackupRun, run.id, authorize?: false).status == :running
  end
end
