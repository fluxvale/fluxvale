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

  defp restore_runs(instance) do
    instance
    |> runs()
    |> Enum.filter(&(&1.kind == :restore))
  end

  defp reload(instance), do: Instance.get_by_id!(instance.id, authorize?: false)

  # A Deployment the controller has fully rolled down — the shape the
  # scale-down wait polls for.
  defp terminated_deployment do
    %{"metadata" => %{"name" => "app"}, "status" => %{"replicas" => 0}}
  end

  defp live_deployment do
    %{"metadata" => %{"name" => "app"}, "status" => %{"replicas" => 1, "readyReplicas" => 1}}
  end

  # The happy-path cluster: kubeconfig, no leftover Jobs, applies succeed,
  # and the app's pods are gone by the time the wait looks.
  defp stub_restore_cluster do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
    stub(Deployment, :get, fn _kc, _ns, "app" -> {:ok, terminated_deployment()} end)
    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
  end

  # The scale-down wait's budget, shortened so a test can pin a timeout
  # without paying the production interval.
  defp scale_down_timeout!(seconds) do
    original = Application.fetch_env!(:flux_vale, :backups)

    Application.put_env(
      :flux_vale,
      :backups,
      Keyword.put(original, :scale_down_timeout_seconds, seconds)
    )

    on_exit(fn -> Application.put_env(:flux_vale, :backups, original) end)
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

      stub_restore_cluster()
      # prior is INHERITED (:running), so the retry scales (already at
      # 0 — idempotent) and waits for the pods on its way to the Job.
      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)
      expect(RestoreJob, :create, fn _kc, ^ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(failed)

      # The retry's row records the pre-FIRST-restore state, not :error
      # — a success returns the app there (ADR-0037 §5).
      assert run.restored_from == :running
      assert reload(failed).status == :restoring
    end

    test "a retry inherits :stopped when the failed run recorded none" do
      owner = user()
      version = base!()
      instance = instance!(version, owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      # A failed restore run whose restored_from is nil (the column is
      # nullable) — Map.get's default never fires on a present-nil key, so
      # the retry would otherwise inherit nil and the sweep's release would
      # fail :unknown_prior_status after a SUCCESSFUL restore.
      run!(instance, %{kind: :restore, status: :failed, restored_from: nil})

      failed =
        InstanceFixtures.pin!(instance, status: :error, failure_reason: :restore_failed)

      stub_restore_cluster()
      # :stopped never scales.
      reject(Deployment, :scale, 4)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(failed)
      assert run.restored_from == :stopped
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

      stub_restore_cluster()
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

  describe "call/1 — ownership" do
    test "a stranger is Forbidden before any cluster call" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stranger = user()

      # No cluster call may happen — not even a kubeconfig read.
      reject(K8s, :kubeconfig, 1)
      reject(Deployment, :scale, 4)
      reject(RestoreJob, :create, 3)
      reject(BackupJob, :delete, 2)

      assert {:error, %Ash.Error.Forbidden{} = error} =
               Infrastructure.restore_instance_backup(instance, actor: stranger)

      assert Exception.message(error) =~ "another organization"

      all_runs = runs(instance)
      restores = Enum.filter(all_runs, &(&1.kind == :restore))
      assert restores == []
      assert reload(instance).status == :running
    end

    test "a stranger cannot slip past the read behind authorize?: false" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      reject(RestoreJob, :create, 3)

      assert {:error, %Ash.Error.Forbidden{}} =
               Infrastructure.restore_instance_backup(instance,
                 actor: user(),
                 authorize?: false
               )

      assert reload(instance).status == :running
    end

    test "the owner restores through the actor-authorized path" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub_restore_cluster()

      assert {:ok, run} = Infrastructure.restore_instance_backup(instance, actor: owner)
      assert run.kind == :restore
      assert reload(instance).status == :restoring
    end

    test "an actorless system call still works (the sweep's recovery arm)" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub_restore_cluster()

      # No actor: the lifecycle ops' authorize?: false posture.
      assert {:ok, run} = Infrastructure.restore_instance_backup(instance)
      assert run.kind == :restore
    end
  end

  describe "call/1 — a running instance" do
    test "scales to 0, waits for termination, lands :restoring, applies the Job" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)
      ns = instance.namespace

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)
      # The wait: the Deployment reports the rollout down before the Job
      # is applied.
      expect(Deployment, :get, fn _kc, ^ns, "app" -> {:ok, terminated_deployment()} end)

      expect(BackupJob, :delete, fn _kc, ^ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :delete, fn _kc, ^ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :create, fn _kc, ^ns, spec ->
        assert spec.slug == instance.slug
        assert spec.mount_path == instance.storage_mount_path
        assert spec.snapshot_id == @snapshot
        # The row's id rides the Job — the sweep's ownership check.
        assert is_binary(spec.run_id)

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

      stub_restore_cluster()

      expect(RestoreJob, :create, fn _kc, _ns, spec ->
        assert spec.snapshot_id == "newest99"
        {:ok, %{}}
      end)

      assert {:ok, _run} = Infrastructure.restore_instance_backup(instance)
    end

    # Review finding: `scale` returns when the API accepts the count — the
    # pods are still writing for a while after. restic's --delete must not
    # meet a live writer, so the Job waits for the Deployment to report
    # zero.
    test "waits past a still-live Deployment, then applies once it is down" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      # A one-second budget is enough for the second poll, and keeps the
      # suite fast (the interval is clamped to the budget).
      scale_down_timeout!(1)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, 0 -> {:ok, %{}} end)

      expect(Deployment, :get, fn _kc, _ns, "app" -> {:ok, live_deployment()} end)
      expect(Deployment, :get, fn _kc, _ns, "app" -> {:ok, terminated_deployment()} end)

      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(instance)
      assert run.status == :running
      assert reload(instance).status == :restoring
    end

    test "a vanished Deployment counts as stopped — nothing is serving the volume" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, 0 -> {:ok, %{}} end)

      # An operator removed the Deployment mid-wait: no app, no writer.
      expect(Deployment, :get, fn _kc, _ns, "app" -> {:error, %Error{reason: :not_found}} end)

      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, _run} = Infrastructure.restore_instance_backup(instance)
    end

    test "an unreadable Deployment fails the run before the Job applies" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      expect(Deployment, :get, fn _kc, _ns, "app" ->
        {:error, Error.connection_error("api hiccup")}
      end)

      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      # The app was scaled down but the volume was never touched: back to
      # service, not :error.
      assert reload(instance).status == :starting
    end

    test "a scale-down that never settles fails the run before the Job applies" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)
      ns = instance.namespace

      # No wait budget at all: the first poll is already past the deadline.
      scale_down_timeout!(0)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)
      expect(Deployment, :get, fn _kc, ^ns, "app" -> {:ok, live_deployment()} end)

      # Nothing is applied to a volume a live app is still writing.
      reject(RestoreJob, :create, 3)

      # The revert puts the app back into service (scale 1, :starting).
      expect(Deployment, :scale, fn _kc, ^ns, "app", 1 -> {:ok, %{}} end)

      assert {:error, %Error{reason: :timeout}} =
               Infrastructure.restore_instance_backup(instance)

      assert [restore] = restore_runs(instance)
      assert restore.status == :failed
      assert restore.error_summary =~ "could not stop the app"
      assert restore.error_summary =~ "the app is unchanged"

      # NOT :error: nothing happened to the volume, so the app is fine and
      # the retry re-enters through the normal guard.
      reverted = reload(instance)
      assert reverted.status == :starting
      assert reverted.failure_reason == nil
    end
  end

  describe "call/1 — a stopped or sleeping instance" do
    test "a stopped instance is not scaled (already at 0) and records :stopped" do
      owner = user()
      instance = instance!(base!(), owner, :stopped)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      # No scale and no wait: scaling an already-0 Deployment is noise.
      reject(Deployment, :scale, 4)
      reject(Deployment, :get, 3)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
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
      reject(Deployment, :get, 3)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
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

    # Review finding: a failure after the run row exists settles the row
    # (no stranded :pending holding the instance's only run slot for the
    # stale horizon).
    test "a :restoring flip that fails settles the run and leaves the app alone" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)
      ns = instance.namespace

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      # The status write itself fails: the instance never leaves :running,
      # so the revert has nothing to undo and must not touch the cluster.
      stub(InstanceK8s, :update_status, fn _instance, _status, _message, _reason ->
        {:error, Error.connection_error("status write refused")}
      end)

      reject(RestoreJob, :create, 3)
      reject(Deployment, :scale, 4)
      reject(Deployment, :get, 3)
      reject(BackupJob, :delete, 2)
      reject(RestoreJob, :delete, 2)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      assert [restore] = restore_runs(instance)
      assert restore.status == :failed
      assert restore.error_summary =~ "restore could not start"
      assert restore.finished_at != nil

      assert reload(instance).status == :running
      refute ns == nil
    end

    test "a failed leftover-Job delete settles the run and reverts to the prior state" do
      owner = user()
      instance = instance!(base!(), owner, :stopped)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(BackupJob, :delete, fn _kc, _ns ->
        {:error, Error.connection_error("delete boom")}
      end)

      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      assert [restore] = restore_runs(instance)
      assert restore.status == :failed
      assert restore.error_summary =~ "delete boom"
      assert restore.error_summary =~ "the app is unchanged"

      # The instance was parked and stays parked — never woken, never
      # landed :error (nothing touched the volume).
      reverted = reload(instance)
      assert reverted.status == :stopped
      assert reverted.failure_reason == nil
      assert reverted.status_message =~ "stays stopped"
    end

    test "a pre-Job failure on a sleeping instance puts it back to sleep, never waking it" do
      owner = user()
      instance = instance!(base!(), owner, :sleeping)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(BackupJob, :delete, fn _kc, _ns ->
        {:error, Error.connection_error("delete boom")}
      end)

      reject(Deployment, :scale, 4)
      reject(Deployment, :get, 3)
      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      reverted = reload(instance)
      assert reverted.status == :sleeping
      assert reverted.status_message =~ "stays asleep"
    end

    test "a leftover restore Job from a previous run is deleted before the apply" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
      stub(Deployment, :get, fn _kc, _ns, "app" -> {:ok, terminated_deployment()} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      # Jobs are immutable: the previous restore's object must go first,
      # and the apply waits for it to be GONE (an SSA onto a terminating
      # Job 4xxs).
      expect(RestoreJob, :delete, fn _kc, _ns -> :ok end)
      expect(RestoreJob, :get, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, run} = Infrastructure.restore_instance_backup(instance)
      assert run.status == :running
    end

    # Review finding: a zombie BACKUP run's restic lock fails every
    # restore (exit 11). The one-active-run index guarantees no legitimate
    # backup Job is in flight, so both fixed-name Jobs are deleted.
    test "both leftover Jobs are deleted before the apply" do
      owner = user()
      instance = instance!(base!(), owner, :stopped)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, _run} = Infrastructure.restore_instance_backup(instance)
    end

    test "the apply waits for a deleted Job object to be gone" do
      owner = user()
      instance = instance!(base!(), owner, :stopped)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :delete, fn _kc, _ns -> :ok end)
      # Still terminating on the first poll (the 202 shape), gone on the
      # second — then the create is allowed.
      expect(RestoreJob, :get, fn _kc, _ns -> {:ok, %{"metadata" => %{}}} end)
      expect(RestoreJob, :get, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      expect(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, _run} = Infrastructure.restore_instance_backup(instance)
    end

    test "a Job that never goes away fails the run honestly, before the apply" do
      owner = user()
      instance = instance!(base!(), owner, :stopped)
      setting!(instance)
      succeeded_backup!(instance)

      original = Application.fetch_env!(:flux_vale, :backups)

      Application.put_env(
        :flux_vale,
        :backups,
        Keyword.put(original, :job_delete_timeout_seconds, 0)
      )

      on_exit(fn -> Application.put_env(:flux_vale, :backups, original) end)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :delete, fn _kc, _ns -> :ok end)
      expect(RestoreJob, :get, fn _kc, _ns -> {:ok, %{"metadata" => %{}}} end)
      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :timeout}} =
               Infrastructure.restore_instance_backup(instance)

      assert [restore] = restore_runs(instance)
      assert restore.status == :failed
      assert restore.error_summary =~ "did not go away"
      assert reload(instance).status == :stopped
    end

    test "an unreadable Job during the go-away wait fails the run" do
      owner = user()
      instance = instance!(base!(), owner, :stopped)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :delete, fn _kc, _ns -> :ok end)

      expect(RestoreJob, :get, fn _kc, _ns ->
        {:error, Error.connection_error("api hiccup")}
      end)

      reject(RestoreJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      assert [restore] = restore_runs(instance)
      assert restore.status == :failed
      assert reload(instance).status == :stopped
    end

    test "a failed Job apply settles the run and reverts the app" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
      stub(Deployment, :get, fn _kc, _ns, "app" -> {:ok, terminated_deployment()} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(RestoreJob, :create, fn _kc, _ns, _spec ->
        {:error, Error.connection_error("apply rejected")}
      end)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.restore_instance_backup(instance)

      assert [restore] = restore_runs(instance)
      assert restore.status == :failed
      assert restore.error_summary =~ "apply rejected"

      # The app is put back: scale 1 and :starting, not :error.
      reverted = reload(instance)
      assert reverted.status == :starting
      assert reverted.failure_reason == nil
    end

    test "a revert that cannot rescale the app lands :error, the honest state" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      succeeded_backup!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :get, fn _kc, _ns, "app" -> {:ok, terminated_deployment()} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      stub(RestoreJob, :create, fn _kc, _ns, _spec ->
        {:error, Error.connection_error("apply rejected")}
      end)

      expect(Deployment, :scale, fn _kc, _ns, _n, 0 -> {:ok, %{}} end)

      expect(Deployment, :scale, fn _kc, _ns, _n, 1 ->
        {:error, Error.connection_error("scale refused")}
      end)

      assert {:error, %Error{}} = Infrastructure.restore_instance_backup(instance)

      errored = reload(instance)
      assert errored.status == :error
      assert errored.failure_reason == :restore_failed
      assert errored.status_message =~ "could not be returned to service"
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

    # Review finding: a kubelet-truncated success can still DECODE
    # (`{"bytes_restored":5}`). Accepting it lands :succeeded with a nil
    # snapshot_id — a run the panel calls good and restorable_snapshot can
    # never find again. A restore success requires the snapshot id.
    test "a decodable success without a snapshot id is a failure" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, _in_restore} = restoring!(instance, :running)

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"bytes_restored":5}),
        exit_code: 0,
        reason: "Completed"
      })

      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.failed_ids

      failed = Ash.get!(BackupRun, run.id, authorize?: false)
      assert failed.status == :failed
      assert failed.snapshot_id == nil
      assert failed.error_summary =~ "no usable outcome"
    end

    test "a wrong-typed byte count is worth zero, not a failed restore" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, _in_restore} = restoring!(instance, :running)

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"snapshot_id":"#{@snapshot}","bytes_restored":"lots"}),
        exit_code: 0,
        reason: "Completed"
      })

      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.succeeded_ids

      finished = Ash.get!(BackupRun, run.id, authorize?: false)
      assert finished.bytes_restored == 0
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

    # Review finding (attribution): the fixed-name restore Job outlives
    # its run, so a verdict only belongs to the row its label names.
    test "a restore Job labeled for ANOTHER run is not this row's verdict" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, in_restore} = restoring!(instance, :running)

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"snapshot_id":"#{@snapshot}","bytes_restored":5}),
        exit_code: 0,
        reason: "Completed",
        run_id: "someone-elses-run"
      })

      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.succeeded_ids == []

      assert Ash.get!(BackupRun, run.id, authorize?: false).status == :running
      assert reload(in_restore).status == :restoring
    end

    test "a restore Job whose label names this run is finalized" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      setting!(instance)
      {run, _in_restore} = restoring!(instance, :running)

      stub_restore_job(%{
        outcome: :succeeded,
        message: ~s({"snapshot_id":"#{@snapshot}","bytes_restored":5}),
        exit_code: 0,
        reason: "Completed",
        run_id: run.id
      })

      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert run.id in summary.succeeded_ids
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

  # --- the crash-recovery arm (F1) --------------------------------------
  #
  # The watch pass finalizes the row and THEN releases the instance. A
  # crash between the two leaves :restoring with no active run, which no
  # other pass revisits — the third pass finishes the release.

  describe "the sweep recovers a stranded :restoring instance" do
    defp stranded!(instance, attrs) do
      {:ok, restoring} = InstanceK8s.update_status(instance, :restoring, nil)
      run = run!(restoring, Map.put(attrs, :kind, :restore))
      {run, restoring}
    end

    # The sweep's cluster: nothing active to watch, nothing due (no
    # settings row), the release's scale-up the only write.
    defp stub_recovery_cluster do
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    end

    test "a succeeded run releases a running app: scale 1, :starting" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      {run, in_restore} = stranded!(instance, %{status: :succeeded, restored_from: :running})
      ns = instance.namespace

      stub_recovery_cluster()
      expect(Deployment, :scale, fn _kc, ^ns, "app", 1 -> {:ok, %{}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.recovered_ids == [in_restore.id]

      started = reload(in_restore)
      assert started.status == :starting
      assert started.status_message =~ "awaiting readiness"

      # The run is untouched — it was already terminal.
      assert Ash.get!(BackupRun, run.id, authorize?: false).status == :succeeded
    end

    test "a succeeded run returns a parked app to :stopped without waking it" do
      owner = user()
      parked = instance!(base!(), owner, :stopped)
      {_run, in_restore} = stranded!(parked, %{status: :succeeded, restored_from: :stopped})

      stub_recovery_cluster()
      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.recovered_ids == [in_restore.id]

      returned = reload(in_restore)
      assert returned.status == :stopped
      assert returned.status_message =~ "stays stopped"
    end

    test "a failed run lands :error/:restore_failed — what the crash skipped" do
      owner = user()
      instance = instance!(base!(), owner, :running)

      {run, in_restore} =
        stranded!(instance, %{
          status: :failed,
          restored_from: :running,
          error_summary: "restic restore exited 1"
        })

      stub_recovery_cluster()
      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.recovered_ids == [in_restore.id]

      errored = reload(in_restore)
      assert errored.status == :error
      assert errored.failure_reason == :restore_failed
      assert errored.status_message =~ "partially restored"

      # The row keeps its own summary; recovery finalizes nothing.
      assert Ash.get!(BackupRun, run.id, authorize?: false).error_summary ==
               "restic restore exited 1"
    end

    test "an instance with an active run is the watch pass's, never recovered" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      {:ok, in_restore} = InstanceK8s.update_status(instance, :restoring, nil)

      run =
        run!(in_restore, %{kind: :restore, status: :running, restored_from: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(RestoreJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.recovered_ids == []
      assert summary.failed_ids == []

      assert Ash.get!(BackupRun, run.id, authorize?: false).status == :running
      assert reload(in_restore).status == :restoring
    end

    test "an instance with no restore run at all is left alone" do
      owner = user()
      instance = instance!(base!(), owner, :running)
      {:ok, in_restore} = InstanceK8s.update_status(instance, :restoring, nil)

      stub_recovery_cluster()
      reject(Deployment, :scale, 4)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.recovered_ids == []
      assert reload(in_restore).status == :restoring
    end

    test "a :restoring instance is not :lost or slept by the other sweeps" do
      # The recovery arm's premise: nothing else converges :restoring.
      owner = user()
      instance = instance!(base!(), owner, :running)
      {:ok, _in_restore} = InstanceK8s.update_status(instance, :restoring, nil)

      stub_recovery_cluster()
      reject(Deployment, :scale, 4)

      assert {:ok, _summary} = Infrastructure.sweep_backups(@now)
    end
  end
end
