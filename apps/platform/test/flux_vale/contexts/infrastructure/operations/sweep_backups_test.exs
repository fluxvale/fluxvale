defmodule FluxVale.Infrastructure.Operations.SweepBackupsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.SweepBackups
  alias FluxVale.Repo
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  # A fixed clock: the due arithmetic is a pure function of (instance,
  # setting, now), so the tests pin instants and never sleep or freeze
  # time. 2026-10-24 is an ordinary Saturday.
  @now DateTime.new!(~D[2026-10-24], ~T[04:00:00], "Etc/UTC")

  defp user do
    User.create!("sweep-backups-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp base! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    version
  end

  defp deployed_instance!(version, owner, opts \\ []) do
    instance =
      Instance.create!(
        %{name: "Swept #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    if Keyword.get(opts, :deployed, true) do
      InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")
    else
      instance
    end
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

  defp run!(instance, attrs) do
    base = %{
      instance_id: instance.id,
      kind: :scheduled,
      status: :running,
      started_at: @now
    }

    BackupRun
    |> Ash.Changeset.for_create(:create, Map.merge(base, Map.new(attrs)), authorize?: false)
    |> Ash.create!()
  end

  defp runs(instance) do
    BackupRun
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_run!(id), do: Ash.get!(BackupRun, id, authorize?: false)

  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    # The due pass's fresh run is watched in the same pass: the Job is
    # applied but has no verdict yet.
    stub(BackupJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)
  end

  # --- DUE ---------------------------------------------------------------

  describe "due — the daily window" do
    test "due after the window opens and no run today" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      stub_k8s()

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)

      assert [run] = runs(instance)
      assert summary.started_ids == [run.id]
      assert run.kind == :scheduled
      assert run.status == :running
    end

    test "not due before the window opens" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      # 02:00 UTC is before schedule_hour (3) for every jitter value.
      early = DateTime.new!(~D[2026-10-24], ~T[02:00:00], "Etc/UTC")

      reject(BackupJob, :create, 3)

      assert {:ok, summary} = Infrastructure.sweep_backups(early)
      assert summary.started_ids == []
      assert runs(instance) == []
    end

    test "the window is schedule_hour plus this instance's minute jitter" do
      owner = user()
      instance = deployed_instance!(base!(), owner)

      opened = SweepBackups.window_opened(instance, @now)
      jitter = SweepBackups.jitter(instance.id)

      window = DateTime.new!(~D[2026-10-24], ~T[03:00:00], "Etc/UTC")
      expected = DateTime.add(window, jitter * 60, :second)

      assert opened == expected
      assert opened.hour == 3
      assert opened.minute == jitter
    end

    test "jitter is stable per instance and stays in 0..59" do
      version = base!()
      owner = user()

      ids = for _n <- 1..20, do: deployed_instance!(version, owner).id

      for id <- ids do
        assert SweepBackups.jitter(id) == SweepBackups.jitter(id)
        assert SweepBackups.jitter(id) in 0..59
      end

      # Different ids spread: 20 draws over 60 minutes should not be one value.
      jitters = Enum.map(ids, &SweepBackups.jitter/1)
      spread = Enum.uniq(jitters)
      assert length(spread) > 1
    end

    test "not due when a run already started since the window opened" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      opened = SweepBackups.window_opened(instance, @now)
      run!(instance, %{started_at: DateTime.add(opened, 60, :second), status: :succeeded})

      reject(BackupJob, :create, 3)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.started_ids == []
      assert length(runs(instance)) == 1
    end

    test "yesterday's run does not satisfy today's window" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run!(instance, %{started_at: DateTime.add(@now, -20 * 3600, :second), status: :succeeded})

      stub_k8s()

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert [yesterday, today] = runs(instance)
      assert summary.started_ids == [today.id]
      refute today.id == yesterday.id
    end

    test "a run from before the window today does not satisfy it either" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      opened = SweepBackups.window_opened(instance, @now)

      existing =
        run!(instance, %{started_at: DateTime.add(opened, -60, :second), status: :succeeded})

      stub_k8s()

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      all_runs = runs(instance)
      started = Enum.reject(all_runs, &(&1.id == existing.id))
      assert [new_run] = started
      assert summary.started_ids == [new_run.id]
    end

    test "catch-up: a missed window is taken by a later sweep the same day" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      stub_k8s()

      # 22:00 — the platform was down at 03:07; the run still happens.
      late = DateTime.new!(~D[2026-10-24], ~T[22:00:00], "Etc/UTC")

      assert {:ok, summary} = Infrastructure.sweep_backups(late)
      assert [run] = runs(instance)
      assert summary.started_ids == [run.id]
    end

    test "a disabled setting is never due" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance, %{enabled: false})

      reject(BackupJob, :create, 3)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.started_ids == []
      assert runs(instance) == []
    end

    test "an instance with no settings row is never due" do
      owner = user()
      instance = deployed_instance!(base!(), owner)

      reject(BackupJob, :create, 3)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.started_ids == []
      assert runs(instance) == []
    end

    test "a never-deployed instance is never due" do
      owner = user()
      instance = deployed_instance!(base!(), owner, deployed: false)
      setting!(instance)

      reject(BackupJob, :create, 3)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.started_ids == []
      assert runs(instance) == []
    end

    test "an active run blocks the due pass without failing it" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      # A manual run started after the window: in flight, so the due pass
      # must not double-start (the operation's guard, not the due math).
      opened = SweepBackups.window_opened(instance, @now)
      run!(instance, %{started_at: DateTime.add(opened, 30, :second), status: :running})

      # The watch pass reads it; the Job is still running.
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)
      reject(BackupJob, :create, 3)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.started_ids == []
      assert summary.failed_ids == []
    end

    test "due?/2 is the pure predicate behind the pass" do
      owner = user()
      instance = deployed_instance!(base!(), owner)

      assert SweepBackups.due?(instance, @now)

      late = DateTime.new!(~D[2026-10-24], ~T[02:00:00], "Etc/UTC")
      refute SweepBackups.due?(instance, late)
    end
  end

  describe "due — per-item isolation" do
    test "a crashing due unit is logged and fails the pass, not the sweep" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :delete, fn _kc, _ns -> raise "k8s api exploded" end)

      assert {:error, "backup sweep failed for 1 unit(s)"} =
               Infrastructure.sweep_backups(@now)
    end

    test "an in-flight run that predates the window is a benign skip, not a failure" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      # Started yesterday and still :running (a long backup, or a row the
      # watch pass has not concluded): today's window sees no run since it
      # opened, so the due pass tries — and the operation's guard, not the
      # due math, is what refuses. The pass stays clean for Oban.
      # 02:00 — before today's window for every jitter value, and well
      # inside the stale horizon.
      run!(instance, %{started_at: DateTime.add(@now, -2 * 3600, :second), status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      reject(BackupJob, :create, 3)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.started_ids == []
      assert summary.failed_ids == []
    end

    test "a non-guard start failure fails the pass (Oban retries the apply)" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      stub(BackupJob, :create, fn _kc, _ns, _spec ->
        {:error, Error.connection_error("apply rejected")}
      end)

      assert {:error, "backup sweep failed for 1 unit(s)"} =
               Infrastructure.sweep_backups(@now)

      # The row is settled :failed by the operation — no stale slot.
      assert [run] = runs(instance)
      assert run.status == :failed
    end
  end

  # --- WATCH -------------------------------------------------------------

  describe "watch — success" do
    test "a succeeded Job finalizes the run with snapshot id and bytes" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      opened = SweepBackups.window_opened(instance, @now)
      run = run!(instance, %{started_at: DateTime.add(opened, 30, :second), status: :running})

      message =
        ~s({"snapshot_id":"6b757e02e6a7","bytes_processed":2048,"bytes_added":1024})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :succeeded, message: message, exit_code: 0, reason: "Completed"}}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.succeeded_ids == [run.id]

      finalized = Repo.reload!(run)
      assert finalized.status == :succeeded
      assert finalized.snapshot_id == "6b757e02e6a7"
      assert finalized.bytes_processed == 2048
      assert finalized.bytes_added == 1024
    end

    # Review finding (attribution): the fixed-name Job outlives its run.
    # A verdict is only this row's if the Job's run-id label names it —
    # a mismatched label means the row keeps waiting (the next run's
    # watch settles it, or the stale horizon does); it must NOT absorb
    # another run's outcome.
    test "a succeeded Job labeled for ANOTHER run is not this row's verdict" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running, started_at: DateTime.add(@now, -60, :second)})

      message =
        ~s({"snapshot_id":"6b757e02e6a7","bytes_processed":2048,"bytes_added":1024})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok,
         %{
           outcome: :succeeded,
           message: message,
           exit_code: 0,
           reason: "Completed",
           run_id: "someone-elses-run"
         }}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.succeeded_ids == []
      assert Repo.reload!(run).status == :running
    end

    # The same ownership gate on the failure arm: another run's failed
    # Job is not this row's verdict either.
    test "a failed Job labeled for ANOTHER run is not this row's verdict" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running, started_at: DateTime.add(@now, -60, :second)})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok,
         %{
           outcome: :failed,
           message: ~s({"error":"restic exited 1"}),
           exit_code: 1,
           reason: "Error",
           run_id: "someone-elses-run"
         }}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == []
      assert Repo.reload!(run).status == :running
    end

    # count_field's lenient arm: a good snapshot id with wrong-typed byte
    # counts still succeeds (bytes default 0 — restic omits zero fields;
    # a bad count must not fail a good backup).
    test "a valid id with wrong-typed byte counts succeeds with zeroed bytes" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running, started_at: DateTime.add(@now, -60, :second)})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok,
         %{
           outcome: :succeeded,
           message:
             ~s({"snapshot_id":"6b757e02e6a7","bytes_processed":"lots","bytes_added":null}),
           exit_code: 0,
           reason: "Completed"
         }}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.succeeded_ids == [run.id]

      finalized = Repo.reload!(run)
      assert finalized.snapshot_id == "6b757e02e6a7"
      assert finalized.bytes_processed == 0
      assert finalized.bytes_added == 0
    end

    # Review finding (poison pill): a decodable but wrong-shaped message
    # (hostile keys, a non-string id) must fail the run honestly —
    # writing it would fail the typed update and re-fail every
    # subsequent 5-minute pass on the same row.
    test "a wrong-shaped success message fails the run, not the pass" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running, started_at: DateTime.add(@now, -60, :second)})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok,
         %{
           outcome: :succeeded,
           message: ~s({"snapshot_id":{"evil":true},"bytes_processed":-1,"bytes_added":{}}),
           exit_code: 0,
           reason: "Completed"
         }}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == [run.id]
      assert Repo.reload!(run).status == :failed
    end

    test "a Complete Job with no usable message is a failure, not a success" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :succeeded, message: "truncated {", exit_code: 0, reason: "Completed"}}
      end)

      stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)

      assert summary.failed_ids == [run.id]

      failed = fetch_run!(run.id)
      assert failed.status == :failed
      assert failed.error_summary =~ "no usable outcome"
    end
  end

  describe "watch — failure" do
    test "a failed Job finalizes :failed with the script's error string" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok,
         %{
           outcome: :failed,
           message: ~s({"error":"restic backup exited 1: Fatal: unable to open repo"}),
           exit_code: 1,
           reason: "Error"
         }}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == [run.id]

      failed = fetch_run!(run.id)
      assert failed.status == :failed
      assert failed.error_summary == "restic backup exited 1: Fatal: unable to open repo"
    end

    test "a failed Job with a non-JSON message falls back to its exit code" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :failed, message: "no newline at end", exit_code: 1, reason: "Error"}}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == [run.id]

      failed = fetch_run!(run.id)
      assert failed.error_summary == "job Error, container exited 1"
    end

    test "a Complete Job with no message at all is a failure" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :succeeded, message: nil, exit_code: 0, reason: "Completed"}}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == [run.id]
      assert fetch_run!(run.id).status == :failed
    end

    test "a failed Job with no message falls back to its exit code and reason" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      retry = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :failed, message: nil, exit_code: nil, reason: "BackoffLimitExceeded"}}
      end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == [retry.id]

      [failed] = runs(instance)
      assert failed.error_summary == "job BackoffLimitExceeded"
    end

    test "a failure with neither message nor reason says so plainly" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :failed, message: nil, exit_code: nil, reason: nil}}
      end)

      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, _summary} = Infrastructure.sweep_backups(@now)

      [failed] = runs(instance)
      assert failed.error_summary == "backup job failed"
    end

    test "a transport failure finalizes with the exit code line" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :failed, message: nil, exit_code: 137, reason: nil}}
      end)

      assert {:ok, _summary} = Infrastructure.sweep_backups(@now)

      [failed] = runs(instance)
      assert failed.error_summary == "container exited 137"
    end

    test "a long error is truncated to the row's 500-char limit" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run!(instance, %{status: :running})
      long = String.duplicate("x", 900)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:ok, %{outcome: :failed, message: ~s({"error":"#{long}"}), exit_code: 1, reason: nil}}
      end)

      assert {:ok, _summary} = Infrastructure.sweep_backups(@now)

      [failed] = runs(instance)
      assert String.length(failed.error_summary) == 500
    end
  end

  describe "watch — the instance or its Job vanished" do
    test "a Job 404 under a gone namespace fails the run 'instance gone'" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, false} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == [run.id]

      failed = fetch_run!(run.id)
      assert failed.status == :failed
      assert failed.error_summary == "instance gone"
    end

    test "a Job 404 under a live namespace is left alone (still fresh)" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, true} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == []

      assert fetch_run!(run.id).status == :running
    end

    test "an unreadable namespace fails the unit for Oban's retry" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(Namespace, :exists?, fn _kc, _ns -> {:error, Error.connection_error("api down")} end)

      assert {:error, "backup sweep failed for 1 unit(s)"} =
               Infrastructure.sweep_backups(@now)

      # Untouched: no verdict was invented from an unreadable cluster.
      assert fetch_run!(run.id).status == :running
    end

    test "a crashing watch unit is logged and fails the pass" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns -> raise "k8s api exploded" end)

      assert {:error, "backup sweep failed for 1 unit(s)"} =
               Infrastructure.sweep_backups(@now)

      assert fetch_run!(run.id).status == :running
    end

    test "a Job read failure fails the unit and leaves the run active" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(BackupJob, :status, fn _kc, _ns ->
        {:error, Error.connection_error("api hiccup")}
      end)

      assert {:error, "backup sweep failed for 1 unit(s)"} =
               Infrastructure.sweep_backups(@now)

      assert fetch_run!(run.id).status == :running
    end
  end

  describe "watch — still running and staleness" do
    test "a still-running Job is left for the next sweep" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      run = run!(instance, %{status: :running})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == []
      assert summary.succeeded_ids == []

      assert fetch_run!(run.id).status == :running
    end

    test "a run past the stale horizon with a live namespace fails stale" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      stale_after = Application.fetch_env!(:flux_vale, :backups)[:stale_after_seconds]

      run =
        run!(instance, %{
          status: :running,
          started_at: DateTime.add(@now, -(stale_after + 60), :second)
        })

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, true} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids == [run.id]

      failed = fetch_run!(run.id)
      assert failed.status == :failed
      assert failed.error_summary =~ "went stale"
    end

    test "a stale run whose Job is still reported running also fails" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      stale_after = Application.fetch_env!(:flux_vale, :backups)[:stale_after_seconds]

      run!(instance, %{
        status: :running,
        started_at: DateTime.add(@now, -(stale_after + 1), :second)
      })

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :status, fn _kc, _ns -> {:ok, %{outcome: :running}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
      stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, summary} = Infrastructure.sweep_backups(@now)
      assert summary.failed_ids != []
    end

    test "stale?/2 is pure over (run, now)" do
      owner = user()
      instance = deployed_instance!(base!(), owner)
      setting!(instance)

      fresh = run!(instance, %{status: :running, started_at: @now})
      refute SweepBackups.stale?(fresh, @now)

      later = DateTime.add(@now, 6 * 3600, :second)
      assert SweepBackups.stale?(fresh, later)
    end
  end
end
