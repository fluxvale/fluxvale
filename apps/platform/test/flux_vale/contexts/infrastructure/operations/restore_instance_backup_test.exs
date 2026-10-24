defmodule FluxVale.Infrastructure.Operations.RestoreInstanceBackupTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.SweepBackups
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @snapshot "6b757e02e6a7c1d8"

  # A fixed clock: the sweep's staleness arithmetic is pure over
  # (run, now), so the tests pin instants and never sleep.
  @now DateTime.new!(~D[2026-10-24], ~T[04:00:00], "Etc/UTC")

  defp user do
    User.create!("restore-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp base! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    version
  end

  # An instance walked to `status` through the real funnel, with the
  # namespace pinned (the deploy action owns it in production).
  defp instance!(version, owner, status) do
    instance =
      Instance.create!(
        %{name: "Restored #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    instance
    |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")
    |> InstanceFixtures.walk_to!(status)
  end

  defp setting!(instance, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          instance_id: instance.id,
          endpoint: "https://account.r2.cloudflarestorage.com",
          bucket: "fluxvale-kavita",
          access_key_id: "AKIAIOSFODNN7EXAMPLE"
        },
        Map.new(overrides)
      )

    BackupSetting
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  # A successful backup — the restore guard's input.
  defp succeeded_backup!(instance, snapshot_id \\ @snapshot) do
    run!(instance, %{kind: :scheduled, status: :succeeded, snapshot_id: snapshot_id})
  end

  # A settled row (whatever the outcome). The outcome fields are
  # finalize-only on the resource, so they are written by a second update —
  # the same two writes the sweep makes.
  @finalize_fields [
    :snapshot_id,
    :bytes_processed,
    :bytes_added,
    :bytes_restored,
    :error_summary
  ]

  defp run!(instance, attrs) do
    base = %{
      instance_id: instance.id,
      kind: :scheduled,
      status: :succeeded,
      started_at: DateTime.utc_now()
    }

    attrs = Map.merge(base, Map.new(attrs))
    {outcome, creatable} = Map.split(attrs, @finalize_fields)

    run =
      BackupRun
      |> Ash.Changeset.for_create(:create, creatable, authorize?: false)
      |> Ash.create!()

    case outcome do
      empty when empty == %{} ->
        run

      finalize ->
        run
        |> Ash.Changeset.for_update(:update, finalize, authorize?: false)
        |> Ash.update!()
    end
  end

  defp runs(instance) do
    BackupRun
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp reload(instance), do: Instance.get_by_id!(instance.id, authorize?: false)

  # The happy-path cluster: kubeconfig, no leftover Job, applies succeed.
  defp stub_restore_cluster do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
    stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
  end

  describe "call/1 — guards" do
    test "no settings row: :no_settings, no run, no cluster write" do
      owner = user()
      instance = instance!(base!(), owner, :running)

      reject(RestoreJob, :create, 3)

      assert {:error, :no_settings} = Infrastructure.restore_instance_backup(instance)
      assert runs(instance) == []
      assert reload(instance).status == :running
    end

    test "a disabled setting: :backups_disabled" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance, %{enabled: false})

      reject(RestoreJob, :create, 3)

      assert {:error, :backups_disabled} = Infrastructure.restore_instance_backup(instance)
      assert runs(instance) == []
      assert reload(instance).status == :running
    end

    test "no succeeded backup to restore: :nothing_to_restore" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      run!(instance, %{kind: :manual, status: :failed, error_summary: "boom"})

      reject(RestoreJob, :create, 3)

      assert {:error, :nothing_to_restore} = Infrastructure.restore_instance_backup(instance)
      assert reload(instance).status == :running
    end

    test "a succeeded backup with no snapshot id is not restorable" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      run!(instance, %{kind: :scheduled, status: :succeeded, snapshot_id: nil})

      reject(RestoreJob, :create, 3)

      assert {:error, :nothing_to_restore} = Infrastructure.restore_instance_backup(instance)
    end

    test "a restore already in flight blocks another" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)
      run!(instance, %{kind: :restore, status: :running, restored_from: :running})

      # The refusal is the partial unique index's rejection (translated),
      # so the op reaches its kubeconfig leg — stub it; the Job create
      # stays rejected.
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      reject(RestoreJob, :create, 3)

      assert {:error, :run_in_flight} = Infrastructure.restore_instance_backup(instance)
      assert reload(instance).status == :running
    end

    test "a backup in flight blocks a restore — one writer per instance" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)
      run!(instance, %{kind: :scheduled, status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      reject(RestoreJob, :create, 3)

      assert {:error, :run_in_flight} = Infrastructure.restore_instance_backup(instance)
    end

    test "a restore cannot start from a state with no volume to write back" do
      owner = user()
      version = base!()
      instance = instance!(version, owner, :running)

      pending =
        Instance.create!(
          %{name: "Fresh #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      setting!(pending)
      succeeded_backup!(pending)

      reject(RestoreJob, :create, 3)

      assert {:error, :not_restorable} = Infrastructure.restore_instance_backup(pending)

      # ...and the same for a row mid-deploy.
      deploying =
        instance
        |> InstanceFixtures.pin!(status: :pending)
        |> InstanceFixtures.walk_to!(:deploying)

      assert {:error, :not_restorable} = Infrastructure.restore_instance_backup(deploying)
    end

    test "a failed restore is retryable: :error + :restore_failed restores again" do
      owner = user()
      version = base!()
      instance = instance!(version, owner, :running)
      setting!(instance)
      succeeded_backup!(instance)
      ns = instance.namespace

      # The first restore failed mid-flight: its run recorded where the
      # app ran (:running), and the failure landed the row :error.
      run!(instance, %{kind: :restore, status: :failed, restored_from: :running})

      failed =
        InstanceFixtures.pin!(instance, status: :error, failure_reason: :restore_failed)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      # prior is INHERITED (:running), so the retry scales (already at
      # 0 — idempotent) on its way to the Job.
      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)
      expect(RestoreJob, :delete, fn _kc, ^ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :create, fn _kc, ^ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(failed)

      # The retry's row records the pre-FIRST-restore state, not :error
      # — a success returns the app there (ADR-0037 §5).
      assert run.restored_from == :running
      assert reload(failed).status == :restoring
    end

    test "a retry with no failed run to inherit falls back to :stopped" do
      owner = user()
      version = base!()
      instance = instance!(version, owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      # A hand-shaped :error/:restore_failed row with no prior restore
      # run — the defensive fallback must never wake the app.
      failed =
        InstanceFixtures.pin!(instance, status: :error, failure_reason: :restore_failed)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      expect(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(failed)
      assert run.restored_from == :stopped
    end

    test "an :error from another failure is not restorable" do
      owner = user()
      version = base!()
      instance = instance!(version, owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      errored =
        InstanceFixtures.pin!(instance, status: :error, failure_reason: :start_failed)

      reject(RestoreJob, :create, 3)

      assert {:error, :not_restorable} = Infrastructure.restore_instance_backup(errored)
    end

    test "a never-deployed instance: :not_deployed" do
      owner = user()
      version = base!()

      instance =
        Instance.create!(
          %{
            name: "Undeployed #{System.unique_integer()}",
            app_version_id: version.id,
            env_vars: %{}
          },
          actor: owner
        )

      setting!(instance)
      succeeded_backup!(instance)

      reject(RestoreJob, :create, 3)

      # Never deployed rows are `:pending`, so the status guard answers
      # first — both refusals are honest, and neither writes anything.
      assert {:error, :not_restorable} = Infrastructure.restore_instance_backup(instance)
      all_runs = runs(instance)
      kinds = Enum.map(all_runs, & &1.kind)
      assert kinds == [:scheduled]
    end

    # Belt and braces behind the status guard: a row that reached a
    # restorable status without a namespace has no volume to write back.
    test "a restorable status with no namespace is :not_deployed" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      unnamed = InstanceFixtures.pin!(instance, namespace: nil)

      reject(RestoreJob, :create, 3)

      assert {:error, :not_deployed} = Infrastructure.restore_instance_backup(unnamed)
      assert reload(instance).status == :running
    end
  end

  describe "call/1 — a running instance" do
    test "scales to 0, lands :restoring, applies the Job, and records the run" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)
      ns = instance.namespace

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)

      expect(RestoreJob, :delete, fn _kc, ^ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :create, fn _kc, ^ns, spec ->
        assert spec == %{
                 slug: instance.slug,
                 mount_path: instance.storage_mount_path,
                 snapshot_id: @snapshot
               }

        {:ok, %{}}
      end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(instance)

      assert run.kind == :restore
      assert run.status == :running
      assert run.restored_from == :running
      assert run.instance_id == instance.id
      assert run.finished_at == nil

      restoring = reload(instance)
      assert restoring.status == :restoring
      # Not a stop: the restore's hold is its own state, and the anchors
      # behave like any leave-:running transition.
      assert restoring.failure_reason == nil
    end

    test "the newest succeeded snapshot is the one restored" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)

      now = DateTime.utc_now()

      run!(instance, %{
        kind: :scheduled,
        status: :succeeded,
        snapshot_id: "older111",
        started_at: DateTime.add(now, -3600, :second)
      })

      run!(instance, %{
        kind: :manual,
        status: :succeeded,
        snapshot_id: "newest99",
        started_at: now
      })

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :create, fn _kc, _ns, spec ->
        assert spec.snapshot_id == "newest99"
        {:ok, %{}}
      end)

      assert {:ok, _run} = Infrastructure.restore_instance_backup(instance)
    end

    test "a failed scale-to-zero settles the run :failed and lands :error" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Deployment, :scale, fn _kc, _ns, _n, 0 ->
        {:error, Error.connection_error("cluster on fire")}
      end)

      # Nothing is applied when the app could not be stopped.
      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      all_runs = runs(instance)
      restores = Enum.filter(all_runs, &(&1.kind == :restore))
      assert [restore] = restores
      assert restore.status == :failed
      assert restore.error_summary =~ "could not be applied"
      assert restore.finished_at != nil

      errored = reload(instance)
      assert errored.status == :error
      assert errored.failure_reason == :restore_failed
      assert errored.status_message =~ "cluster on fire"
    end
  end

  describe "call/1 — a stopped or sleeping instance" do
    test "a stopped instance is not scaled (already at 0) and records :stopped" do
      owner = user()
      instance = instance!(base!(), owner, :stopped)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      # No scale call at all: scaling an already-0 Deployment is noise.
      reject(Deployment, :scale, 4)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(instance)
      assert run.restored_from == :stopped

      assert reload(instance).status == :restoring
    end

    test "a sleeping instance stays asleep — recorded, not woken" do
      owner = user()
      instance = instance!(base!(), owner, :sleeping)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      reject(Deployment, :scale, 4)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(instance)
      assert run.restored_from == :sleeping
    end
  end

  describe "call/1 — cluster failures" do
    test "a kubeconfig failure writes no run and changes nothing" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)

      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      assert length(runs(instance)) == 1
      assert reload(instance).status == :running
    end

    test "a failed leftover-Job delete settles the run and lands :error" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      expect(RestoreJob, :delete, fn _kc, _ns ->
        {:error, Error.connection_error("delete boom")}
      end)

      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      all_runs = runs(instance)
      restores = Enum.filter(all_runs, &(&1.kind == :restore))
      assert [restore] = restores
      assert restore.status == :failed

      assert reload(instance).failure_reason == :restore_failed
    end

    test "a leftover restore Job from a previous run is deleted before the apply" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      # Jobs are immutable: the previous restore's object must go first.
      expect(RestoreJob, :delete, fn _kc, _ns -> :ok end)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(instance)
      assert run.status == :running
    end

    test "a failed Job apply settles the run and lands :error" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :create, fn _kc, _ns, _spec ->
        {:error, Error.connection_error("apply rejected")}
      end)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      all_runs = runs(instance)
      restores = Enum.filter(all_runs, &(&1.kind == :restore))
      assert [restore] = restores
      assert restore.status == :failed
      assert restore.error_summary =~ "apply rejected"
    end

    test "another instance's run never blocks this one" do
      owner = user()
      version = base!()
      mine = instance!(version, owner, :running)
      theirs = instance!(version, owner, :running)
      setting!(mine)
      succeeded_backup!(mine)
      run!(theirs, %{kind: :restore, status: :running})

      stub_restore_cluster()

      assert {:ok, _run} = Infrastructure.restore_instance_backup(mine)
    end
  end

  # --- the watch pass's restore arms -----------------------------------

  describe "the sweep finalizes a restore" do
    defp restore_in_flight!(instance, from) do
      run!(instance, %{kind: :restore, status: :running, restored_from: from})
    end

    # The cluster the sweep reads: the restore Job's verdict is the
    # subject, the backup Job and due-pass applies only need to succeed.
    defp stub_restore_job(outcome) do
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RestoreJob, :status, fn _kc, _ns -> {:ok, outcome} end)
    end

    # A restore that is really in flight: the row AND the status hold.
    defp restoring!(instance, from) do
      run = restore_in_flight!(instance, from)
      {:ok, restoring} = InstanceK8s.update_status(instance, :restoring, nil)
      {run, restoring}
    end

    test "success on a running instance scales back to 1 and lands :starting" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, in_restore} = restoring!(instance, :running)
      ns = instance.namespace

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"snapshot_id":"#{@snapshot}","bytes_restored":4096}),
        exit_code: 0,
        reason: "Completed"
      })

      expect(Deployment, :scale, fn _kc, ^ns, "app", 1 -> {:ok, %{}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.succeeded_ids

      finished = Ash.get!(BackupRun, run.id, authorize?: false)
      assert finished.status == :succeeded
      assert finished.snapshot_id == @snapshot
      assert finished.bytes_restored == 4096

      started = reload(in_restore)
      assert started.status == :starting
      # The reconciler stays the only writer of :running.
      assert started.status_message =~ "awaiting readiness"
    end

    test "success on a stopped instance returns to :stopped without waking it" do
      owner = user()
      version = base!()
      parked = instance!(version, owner, :stopped)
      setting!(parked)
      {run, stopped} = restoring!(parked, :stopped)

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"snapshot_id":"#{@snapshot}","bytes_restored":10}),
        exit_code: 0,
        reason: "Completed"
      })

      # No scale-up: the owner parked the app and a restore never wakes it.
      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.succeeded_ids

      returned = reload(stopped)
      assert returned.status == :stopped
      assert returned.status_message =~ "stays stopped"
    end

    test "success on a sleeping instance returns to :sleeping without waking it" do
      owner = user()
      asleep = instance!(base!(), owner, :sleeping)
      setting!(asleep)
      {run, sleeping} = restoring!(asleep, :sleeping)

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"snapshot_id":"#{@snapshot}","bytes_restored":0}),
        exit_code: 0,
        reason: "Completed"
      })

      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.succeeded_ids

      returned = reload(sleeping)
      assert returned.status == :sleeping
      assert returned.status_message =~ "stays asleep"
    end

    test "failure lands the run :failed and the instance :error/:restore_failed" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, in_restore} = restoring!(instance, :running)

      stub_restore_job(%{
        outcome: :failed,
        message: ~s({"error":"restic restore exited 12: wrong password"}),
        exit_code: 12,
        reason: "Error"
      })

      # A failed restore never scales back up.
      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.failed_ids

      failed = Ash.get!(BackupRun, run.id, authorize?: false)
      assert failed.status == :failed
      assert failed.error_summary == "restic restore exited 12: wrong password"

      errored = reload(in_restore)
      assert errored.status == :error
      assert errored.failure_reason == :restore_failed
      # The admin detail says the volume may be partial — the user copy
      # (friendly, no leaks) is InstanceStatus's.
      assert errored.status_message =~ "partially restored"
    end

    test "a Complete Job with no usable message is a failure, not a success" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, in_restore} = restoring!(instance, :running)

      stub_restore_job(%{
        outcome: :succeeded,
        message: "truncated {",
        exit_code: 0,
        reason: "Completed"
      })

      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.failed_ids

      failed = Ash.get!(BackupRun, run.id, authorize?: false)
      assert failed.status == :failed
      assert failed.error_summary =~ "no usable outcome"

      assert reload(in_restore).failure_reason == :restore_failed
    end

    test "a scale-up failure after a good restore lands :error, not a false :starting" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, in_restore} = restoring!(instance, :running)

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"snapshot_id":"#{@snapshot}","bytes_restored":5}),
        exit_code: 0,
        reason: "Completed"
      })

      expect(Deployment, :scale, fn _kc, _ns, _n, 1 ->
        {:error, Error.connection_error("scale refused")}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      # The row is still a success — the restore itself worked.
      assert run.id in summary.succeeded_ids

      errored = reload(in_restore)
      assert errored.status == :error
      assert errored.failure_reason == :restore_failed
      assert errored.status_message =~ "could not be restarted"
    end

    test "a still-running restore is left for the next sweep" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, _in_restore} = restoring!(instance, :running)

      stub_restore_job(%{outcome: :running, message: nil, exit_code: nil, reason: nil})

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.succeeded_ids == []
      assert summary.failed_ids == []

      still_running = Ash.get!(BackupRun, run.id, authorize?: false)
      assert still_running.status == :running
      assert reload(instance).status == :restoring
    end

    test "a stale restore fails the run and the instance" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)

      stale_after = Application.fetch_env!(:flux_vale, :backups)[:stale_after_seconds]

      {:ok, in_restore} = InstanceK8s.update_status(instance, :restoring, nil)

      run =
        run!(in_restore, %{
          kind: :restore,
          status: :running,
          restored_from: :running,
          started_at: DateTime.add(@now, -(stale_after + 60), :second)
        })

      stub_restore_job(%{outcome: :running, message: nil, exit_code: nil, reason: nil})

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.failed_ids

      assert reload(instance).failure_reason == :restore_failed
    end

    test "a restore run never satisfies the day's backup window" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)

      # A restore that started after the window opened: it is not a
      # backup, so today's window is still open for the due pass.
      opened = SweepBackups.window_opened(instance, @now)

      run!(instance, %{
        kind: :restore,
        status: :succeeded,
        restored_from: :running,
        snapshot_id: @snapshot,
        started_at: DateTime.add(opened, 30, :second)
      })

      # The due pass applies a real backup Job; the restore Job's own
      # stubs are present but unused.
      stub_restore_cluster()
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)

      # The due pass started a real backup alongside it.
      assert [started | _rest] = summary.started_ids
      backup = Ash.get!(BackupRun, started, authorize?: false)
      assert backup.kind == :scheduled
    end
  end
end
