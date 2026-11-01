defmodule FluxVale.Infrastructure.Operations.SweepBackups do
  @moduledoc """
  The backup sweep (#222, ADR-0037 §3) — one Oban pass every five
  minutes, three passes per call:

  - **DUE**: instances with enabled settings whose daily window has
    opened and that have not started a run since it did →
    `RunInstanceBackup.call(instance, :scheduled)`.
  - **WATCH**: runs still `:pending`/`:running` → read the Job and
    finalize.
  - **RECOVER**: `:restoring` instances left behind by a crash between a
    restore's finalize and its release (below).

  `now` is a parameter, never `DateTime.utc_now/0` inside the arithmetic:
  the worker passes the clock, tests pass fixed instants, and the due
  window is a pure function of (instance, setting, now). No sleeping, no
  time-freezing.

  ## Restores ride the same watch pass (#222, ADR-0037 §5)

  A `kind: :restore` run is a row like any other, so the watch pass picks
  it up — but finalizing it does more than write the row. The restore
  Job's job is the instance, so success releases the instance: back to
  `:starting` (and the Deployment scaled to 1) when the app was running
  before, back to `:stopped`/`:sleeping` untouched when it was not. The
  pre-restore status comes from the run's own `restored_from` — the sweep
  cannot recompute it, because by finalize time the Deployment has been at
  0 for minutes and `:stopped` and `:sleeping` look identical from the
  cluster's side.

  A restore's watch reads `RestoreJob`, not `BackupJob` (different fixed
  name); the due pass is backup-only, and a restore run never satisfies a
  day's backup window — restoring a snapshot is not backing one up.

  ## The crash-recovery arm (`:restoring` with no active run)

  The watch pass finalizes the row and *then* releases the instance —
  scale up, status write. A crash in that window leaves the row
  `:succeeded` and the instance `:restoring`, at 0 replicas, and no pass
  would ever revisit it: `active_runs` reads only `:pending`/`:running`,
  and every owner action's guard refuses `:restoring`. So the sweep's
  third pass looks for exactly that shape — a `:restoring` instance with
  no active run whose latest `:restore` run is terminal — and finishes
  the release the crashed pass never got to: `:succeeded` releases via
  the run's `restored_from` (the same code the watch pass calls),
  `:failed` lands the `:error`/`:restore_failed` the watch pass's
  `fail_instance` would have.

  The arm is why `:restoring` is not a trap: the status is the
  user-visible claim, and this pass is what makes the claim
  self-healing.

  ## The window

  Daily at `schedule_hour` UTC (config `:backups`), plus a per-instance
  minute jitter derived from the instance id (`:erlang.phash2/2` over 60)
  — a fleet of instances must not all open one 03:00 Job at once. The
  window is "today at schedule_hour:jitter", and it has opened when
  `now >= window`. A missed window (platform down at 03:07) is caught up
  by the next sweep the same day: the check is "has a run started since
  the window opened", not "did we run at the window".

  The user controls `enabled` and `retention_keep`; the clock is not a
  knob in v1 (ADR-0037 §3).

  ## Isolation and failure

  Per-item isolation, the sibling sweeps' shape: one bad instance is
  logged and skipped, every other unit still processes, and the pass
  returns `{:error, reason}` so Oban retries. A guard rejection from
  `RunInstanceBackup` (`:run_in_flight`, `:backups_disabled`,
  `:wallet_unfunded`) is not a failure — it is the sweep racing a
  manual run, an owner's toggle, or an org waiting on its top-up, and
  the next pass re-decides.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RunInstanceBackup

  require Ash.Query
  require Logger

  # Run guards that mean "someone else owns this decision right now" —
  # a manual run started, or the owner disabled backing up mid-pass —
  # plus the wallet gate: a never-paid or zero-balance org's due
  # instance waits for its owner's top-up, never an Oban retry.
  @benign_guards [:run_in_flight, :backups_disabled, :no_settings, :wallet_unfunded]

  @enforce_keys [:started_ids, :succeeded_ids, :failed_ids, :recovered_ids]
  defstruct [:started_ids, :succeeded_ids, :failed_ids, :recovered_ids]

  @type t :: %__MODULE__{
          started_ids: [Ash.UUID.t()],
          succeeded_ids: [Ash.UUID.t()],
          failed_ids: [Ash.UUID.t()],
          recovered_ids: [Ash.UUID.t()]
        }

  @doc """
  One sweep pass. `{:ok, summary}` when every unit processed;
  `{:error, reason}` if any unit failed (the rest still processed — the
  caller's Oban retry owns recovery).
  """
  @spec call(DateTime.t()) :: {:ok, t()} | {:error, String.t()}
  def call(%DateTime{} = now) do
    # Watch first, then start: a run this pass creates has a Job applied
    # microseconds ago, so reading it now is wasted work — and a pass that
    # started runs before reading outstanding ones would watch its own
    # fresh rows against a Job that has not scheduled yet. The recovery
    # arm runs last: a run the watch pass just finalized has had its
    # release attempted, so only a genuinely stranded instance is left.
    results =
      Enum.map(active_runs(), &safe_watch(&1, now)) ++
        Enum.map(due_instances(), &safe_due(&1, now)) ++
        Enum.map(restoring_orphans(), &safe_recover(&1, now))

    failure_count = Enum.count(results, &match?({:error, _reason}, &1))

    if failure_count == 0 do
      {:ok, summarize(results)}
    else
      {:error, "backup sweep failed for #{failure_count} unit(s)"}
    end
  end

  # --- DUE -------------------------------------------------------------

  # Enabled settings only, one query: the settings row is the switch, and
  # an instance without one was never configured.
  defp due_instances do
    BackupSetting
    |> Ash.Query.filter(enabled == true)
    |> Ash.Query.load(:instance)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.instance)
    |> Enum.reject(&is_nil/1)
  end

  defp safe_due(instance, now) do
    due(instance, now)
  rescue
    exception ->
      Logger.error("Backup due pass failed for #{instance.id}: #{Exception.message(exception)}")

      {:error, exception}
  end

  # A never-deployed instance is not due: nothing to read. Logged at
  # debug — configuration before first deploy is the normal order.
  defp due(%Instance{namespace: nil} = instance, _now) do
    Logger.debug("Backup due check skipped for #{instance.id}: not deployed")

    {:ok, nil}
  end

  defp due(instance, now) do
    if due?(instance, now) do
      start(instance)
    else
      {:ok, nil}
    end
  end

  defp start(instance) do
    case RunInstanceBackup.call(instance, :scheduled) do
      {:ok, run} -> {:ok, {:started, run.id}}
      {:error, reason} when reason in @benign_guards -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The due predicate — pure over (instance, now), public for its test.

  Due means all of: the window for `now`'s date has opened, and no run
  started since it did. `run_in_flight` is not consulted here: the
  operation's guard owns it, so a sweep racing a manual run skips
  cleanly rather than two places deciding the same thing.
  """
  @spec due?(Instance.t(), DateTime.t()) :: boolean()
  def due?(%Instance{} = instance, %DateTime{} = now) do
    opened = window_opened(instance, now)

    DateTime.compare(now, opened) != :lt and not ran_since?(instance, opened)
  end

  @doc """
  When `now`'s daily window opens for `instance` — `schedule_hour` UTC
  plus the instance's own minute jitter (`0..59`).
  """
  @spec window_opened(Instance.t(), DateTime.t()) :: DateTime.t()
  def window_opened(%Instance{id: id}, %DateTime{} = now) do
    date = DateTime.to_date(now)
    midnight = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

    DateTime.add(midnight, schedule_hour() * 3600 + jitter(id) * 60, :second)
  end

  @doc """
  The instance's stable minute offset — `:erlang.phash2/2` over 60, so the
  same id always lands in the same minute and the fleet spreads evenly.
  """
  @spec jitter(Ash.UUID.t()) :: 0..59
  def jitter(id), do: :erlang.phash2(id, 60)

  defp ran_since?(instance, opened) do
    BackupRun
    |> Ash.Query.filter(
      instance_id == ^instance.id and started_at >= ^opened and
        kind in [:scheduled, :manual]
    )
    |> Ash.exists?(authorize?: false)
  end

  # --- WATCH -----------------------------------------------------------

  defp active_runs do
    # The resource's own :active read — the sweep never keeps a second
    # copy of the invariant's filter (review finding).
    BackupRun
    |> Ash.Query.for_read(:active)
    |> Ash.Query.load(:instance)
    |> Ash.read!(authorize?: false)
  end

  defp safe_watch(run, now) do
    watch(run, now)
  rescue
    exception ->
      Logger.error("Backup watch pass failed for run #{run.id}: #{Exception.message(exception)}")

      {:error, exception}
  end

  defp watch(run, now) do
    case run.instance do
      %Instance{namespace: namespace} when is_binary(namespace) ->
        read_job(run, run.instance, now)

      # coveralls-ignore-start - unreachable through the operation: it
      # refuses to start a run without a namespace, and the FK cascade
      # deletes a run with its instance, so neither "no namespace" nor
      # "no instance" can be staged in a test. The honest terminal state
      # if it ever happens is failure, not a slot held forever.
      _gone ->
        finish_failed(run, "instance gone", now)
        # coveralls-ignore-stop
    end
  end

  # The Job module is the only thing the two directions do not share: the
  # restore Job has its own fixed name in the same namespace.
  defp read_job(run, instance, now) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      status = job_status(run, kubeconfig, instance)
      settle_outcome(status, run, instance, kubeconfig, now)
    end
  end

  defp settle_outcome({:ok, %{outcome: :succeeded} = outcome}, run, instance, _kc, now) do
    owned(run, outcome, now, fn run_ -> finish_succeeded(run_, instance, outcome, now) end)
  end

  defp settle_outcome({:ok, %{outcome: :failed} = outcome}, run, _instance, _kc, now) do
    owned(run, outcome, now, fn run_ -> finish_failed(run_, failure_text(outcome), now) end)
  end

  defp settle_outcome({:ok, %{outcome: :running}}, run, _instance, _kc, now) do
    stale(run, now)
  end

  defp settle_outcome({:error, %Error{reason: :not_found}}, run, instance, kubeconfig, now) do
    gone_or_stale(run, instance, kubeconfig, now)
  end

  defp settle_outcome({:error, _error} = error, _run, _instance, _kc, _now), do: error

  # The fixed-name Job outlives its run (immutable objects, deleted only
  # at the next start): a verdict is only this row's if the Job's
  # run-id label names it. A mismatch is not an error — the row simply
  # keeps waiting (the stale horizon settles it, or the next run's watch
  # does). A nil label is a pre-label Job: none exist outside a single
  # deploy, proceed (one-release backward compatibility). Same stance for
  # both directions — a restore run reading a backup Job's verdict (or
  # another restore's) is the identical attribution bug.
  defp owned(run, outcome, now, settle) do
    # Map.get, not dot access: the outcome map is our own builder's
    # shape in production, but a stub or an older build may omit the
    # key — dot access would raise and fail the whole pass.
    case Map.get(outcome, :run_id) do
      nil -> settle.(run)
      run_id when run_id == run.id -> settle.(run)
      _other_run -> stale(run, now)
    end
  end

  # The Job module is the only thing the two directions do not share: the
  # restore Job has its own fixed name in the same namespace.
  defp job_status(%BackupRun{kind: :restore}, kubeconfig, instance) do
    RestoreJob.status(kubeconfig, instance.namespace)
  end

  defp job_status(%BackupRun{}, kubeconfig, instance) do
    BackupJob.status(kubeconfig, instance.namespace)
  end

  # A missing Job is either "the namespace went with it" (the instance is
  # gone — terminal, honest) or "the Job was deleted under a live
  # namespace" (stale — the platform's own next run replaced it, or an
  # operator removed it). Only a definitive namespace 404 says gone; an
  # unreadable namespace fails the unit for Oban's retry.
  defp gone_or_stale(run, instance, kubeconfig, now) do
    case Namespace.exists?(kubeconfig, instance.namespace) do
      {:ok, false} -> finish_failed(run, "instance gone", now)
      {:ok, true} -> stale(run, now)
      {:error, _error} = error -> error
    end
  end

  # Still running, or Job-less under a live namespace: leave it — unless
  # it has outlived the stale horizon, which no real run does.
  defp stale(run, now) do
    if stale?(run, now) do
      finish_failed(run, "backup run went stale: no k8s job reported an outcome", now)
    else
      {:ok, nil}
    end
  end

  @doc """
  Has `run` outlived the stale horizon? Public for its test; the horizon
  is a config value and `now` is the pass's clock, so the arithmetic is a
  pure function of (row, now).
  """
  @spec stale?(BackupRun.t(), DateTime.t()) :: boolean()
  def stale?(run, now) do
    DateTime.diff(now, run.started_at, :second) > stale_after_seconds()
  end

  defp finish_succeeded(%BackupRun{kind: :restore} = run, instance, outcome, now) do
    case decode(outcome.message) do
      {:ok, parsed} ->
        with {:ok, snapshot_id, bytes_restored} <- usable_restore_outcome(parsed),
             {:ok, finished} <-
               finalize_row(run, %{
                 status: :succeeded,
                 snapshot_id: snapshot_id,
                 bytes_restored: bytes_restored,
                 finished_at: now
               }),
             {:ok, _released} <- release_instance(run, instance, now) do
          tagged(finished.status, finished.id)
        else
          # A parseable-but-wrong-shaped outcome is NOT a success: a
          # kubelet-truncated message can decode as `{"bytes_restored":5}`
          # and would otherwise land :succeeded with a nil snapshot_id —
          # a run the panel calls good and `restorable_snapshot` can never
          # find again. Fail it with the honest reason.
          :error ->
            unusable_restore(run, now)

          # coveralls-ignore-start - defensive: the finalize and release
          # writes fail only on a DB outage (DBConnection reconnects — the
          # repo's cluster-level stance), and ExUnit cannot stage one.
          {:error, _write_error} = error ->
            error
            # coveralls-ignore-stop
        end

      # The Job said Complete but the termination log is missing or
      # unparseable: an unknown restore outcome is not a success — the
      # volume's state is exactly what the platform cannot vouch for.
      :error ->
        unusable_restore(run, now)
    end
  end

  defp finish_succeeded(run, _instance, outcome, now) do
    case decode(outcome.message) do
      {:ok, parsed} ->
        case usable_outcome(parsed) do
          {:ok, snapshot_id, bytes_processed, bytes_added} ->
            finalize(run, %{
              status: :succeeded,
              snapshot_id: snapshot_id,
              bytes_processed: bytes_processed,
              bytes_added: bytes_added,
              finished_at: now
            })

          # A parseable-but-wrong-shaped outcome (hostile keys, negative
          # counts, a non-string id) is NOT a success — writing it would
          # fail the typed update and poison every 5-minute pass on the
          # same row (review finding). Fail the run with the honest
          # reason instead.
          :error ->
            finish_failed(run, "backup reported an unusable outcome", now)
        end

      # The Job said Complete but the termination log is missing or
      # unparseable: the backup's outcome is unknown, and an unknown
      # backup is not a success (ADR-0037: retention exists so a bad
      # snapshot is never the only copy — but the panel must not lie).
      :error ->
        finish_failed(run, "backup finished but reported no usable outcome", now)
    end
  end

  # Jason.decode on our own one-line JSON; a truncating kubelet (the
  # termination message cap) is the realistic malformed case.
  defp decode(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp decode(_message), do: :error

  # The typed shape the row can actually store: a string id and
  # non-negative integers. Everything else (hostile keys, floats,
  # negatives, giant numbers) is rejected BEFORE the write — a failed
  # cast inside finalize would leave the row :running and fail every
  # subsequent pass on it (the poison-pill shape).
  defp usable_outcome(parsed) do
    with {:ok, snapshot_id} <- string_field(parsed, "snapshot_id"),
         {:ok, bytes_processed} <- count_field(parsed, "bytes_processed"),
         {:ok, bytes_added} <- count_field(parsed, "bytes_added") do
      {:ok, snapshot_id, bytes_processed, bytes_added}
    end
  end

  defp string_field(parsed, key) do
    case Map.get(parsed, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp count_field(parsed, key) do
    case Map.get(parsed, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:ok, 0}
    end
  end

  # A restore success REQUIRES the snapshot id it claims to have written
  # back — the row's whole point, and `restorable_snapshot` filters rows
  # without one, so a nil id is a run the panel calls good but no restore
  # can ever find. Bytes stay lenient: restic omits `bytes_restored` at
  # zero, and a wrong-typed count is worth 0, not a failed restore.
  defp usable_restore_outcome(parsed) do
    case Map.get(parsed, "snapshot_id") do
      snapshot_id when is_binary(snapshot_id) and snapshot_id != "" ->
        {:ok, snapshot_id, restore_bytes(parsed)}

      _missing_or_wrong_typed ->
        :error
    end
  end

  defp restore_bytes(parsed) do
    case Map.get(parsed, "bytes_restored") do
      bytes when is_integer(bytes) and bytes >= 0 -> bytes
      _absent_or_wrong_typed -> 0
    end
  end

  defp unusable_restore(run, now) do
    finish_failed(run, "restore finished but reported no usable outcome", now)
  end

  defp failure_text(%{message: message} = outcome) when is_binary(message) do
    case decode(message) do
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _no_json -> raw_failure(outcome)
    end
  end

  defp failure_text(outcome), do: raw_failure(outcome)

  # The Job's own words when the script never wrote a message (image
  # pull failure, quota rejection, eviction) — exit code and reason, no
  # pod logs.
  defp raw_failure(%{exit_code: exit_code, reason: reason}) do
    parts =
      Enum.reject(
        [reason && "job #{reason}", exit_code && "container exited #{exit_code}"],
        &is_nil/1
      )

    case parts do
      [] -> "backup job failed"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp finish_failed(run, summary, now) do
    with {:ok, failed} <-
           finalize_row(run, %{
             status: :failed,
             error_summary: truncate(summary),
             finished_at: now
           }),
         {:ok, _released} <- fail_instance(run, failed) do
      tagged(failed.status, failed.id)
    end
  end

  # Backup failures stop at the row (ADR-0037's consequences: backup health
  # and app health are separate axes — the app keeps running).
  # The instance write is STATUS-GUARDED (CodeRabbit): the run's loaded
  # instance is a stale snapshot. A crash between create_run and the
  # :restoring flip leaves a :running app under a :pending row — the
  # stale horizon must not flip that healthy app to :error. And a
  # :restoring row whose namespace vanished mid-run goes :lost via the
  # stranded sweep (#196) — :error must not overwrite the re-deploy
  # door. Only a row that still reads :restoring lands the failure.
  defp fail_instance(%BackupRun{kind: :restore} = run, _failed) do
    case run.instance do
      %Instance{} = instance ->
        case current_status(instance) do
          {:ok, :restoring} -> land_failed_restore(instance)
          _not_restoring -> {:ok, nil}
        end

      # coveralls-ignore-start - unreachable: the FK cascade deletes the
      # run with its instance, and watch/2 already refuses a run whose
      # instance is missing.
      _gone ->
        {:ok, nil}
        # coveralls-ignore-stop
    end
  end

  defp fail_instance(_run, _failed), do: {:ok, nil}

  # The row's loaded instance can be minutes old (the watch pass reads
  # it once at load); re-read the status row before writing state.
  defp current_status(instance) do
    case Instance.get_by_id(instance.id, authorize?: false) do
      {:ok, fresh} ->
        {:ok, fresh.status}

      # coveralls-ignore-start - defensive: the FK cascade deletes runs
      # with their instance; a row whose instance vanished between the
      # load and this read has nothing to write anyway.
      {:error, _gone} ->
        {:error, :gone}
        # coveralls-ignore-stop
    end
  end

  # A restore that failed AFTER its Job ran may have written a partial
  # volume: :error is the honest state, and :restore_failed is the owner's
  # retry door (ADR-0037 §5). Shared with the recovery arm so a crashed
  # finalize lands exactly what the watch pass would have.
  defp land_failed_restore(instance) do
    instance
    |> InstanceK8s.update_status(
      :error,
      "Restore failed; the volume may be in a partially restored state",
      :restore_failed
    )
    |> release_outcome()
  end

  # Success releases the instance: the app was running → scale back to 1
  # and land :starting (the reconciler re-confirms readiness — it stays the
  # only writer of :running); the app was stopped/asleep → back to that
  # state, never woken.
  defp release_instance(run, instance, _now) do
    case run.restored_from do
      :running -> restart_app(instance)
      prior -> restore_prior(instance, prior)
    end
  end

  defp restart_app(instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, _deployment} <- Deployment.scale(kubeconfig, instance.namespace, "app", 1) do
      instance
      |> InstanceK8s.update_status(:starting, "Starting; awaiting readiness")
      |> release_outcome()
    else
      # The volume is restored but the app could not come back: :error is
      # the honest state (a :sleeping/:stopped row here would claim the app
      # is deliberately down and hide the failure).
      {:error, error} -> restore_failed(instance, error)
    end
  end

  # :stopped and :sleeping are already at 0 replicas — nothing to scale,
  # and a restore never wakes an app the owner (or the idle sweep) parked.
  defp restore_prior(instance, prior) when prior in [:stopped, :sleeping] do
    # updated_at must reflect the restore's end, but the status is the
    # same value → a message-only write through the funnel.
    instance
    |> InstanceK8s.update_status(prior, restore_message(prior))
    |> release_outcome()
  end

  # coveralls-ignore-start - defensive: restored_from is written from the
  # @restorable_statuses guard's set, so only those three can appear. A
  # hand-edited row falls back to the honest failure rather than guessing.
  defp restore_prior(instance, _prior) do
    restore_failed(instance, :unknown_prior_status)
  end

  # coveralls-ignore-stop

  defp restore_message(:stopped), do: "Restore finished; your app stays stopped"
  defp restore_message(:sleeping), do: "Restore finished; your app stays asleep"

  defp restore_failed(instance, error) do
    instance
    |> InstanceK8s.update_status(
      :error,
      "Restore finished but the app could not be restarted: " <>
        InstanceK8s.format_error(error),
      :restore_failed
    )
    |> release_outcome()
  end

  # Every release arm's shape is {:ok, instance} | {:error, error}; the
  # sweep's finalize only needs to know whether the unit succeeded.
  defp release_outcome({:ok, _instance}), do: {:ok, nil}

  # The release writes :error from any state and the status funnel only
  # fails on a DB outage, which ExUnit cannot stage (DBConnection
  # reconnects — the repo's cluster-level stance).
  # coveralls-ignore-next-line
  defp release_outcome({:error, _error} = error), do: error

  defp finalize(run, attrs) do
    case finalize_row(run, attrs) do
      {:ok, finished} -> tagged(finished.status, finished.id)
      # coveralls-ignore-next-line
      {:error, _error} = error -> error
    end
  end

  defp finalize_row(run, attrs) do
    case run
         |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
         |> Ash.update() do
      {:ok, finished} ->
        {:ok, finished}

      # Defensive: the finalize write fails only on a concurrent terminal
      # write (the same run finalized twice — a sweep overlapping itself)
      # or the DB going away; ExUnit can't stage either. The next pass
      # reads the settled row and does nothing with it.
      # coveralls-ignore-start
      {:error, error} ->
        Logger.warning("Backup run #{run.id} finalize failed: #{inspect(error)}")

        {:error, error}
        # coveralls-ignore-stop
    end
  end

  defp tagged(:succeeded, id), do: {:ok, {:succeeded, id}}
  defp tagged(:failed, id), do: {:ok, {:failed, id}}

  # The row's own 500-char limit is the contract; the sweep truncates so a
  # long restic line never fails the write itself.
  defp truncate(summary) when is_binary(summary), do: String.slice(summary, 0, 500)

  # --- RECOVER ---------------------------------------------------------

  # The crash-recovery arm (see moduledoc): a :restoring instance with no
  # active run. The watch pass finalizes the row, then releases the
  # instance — a crash between the two leaves the status behind with no
  # run for any pass to revisit. Both of the release's halves are the
  # watch pass's own functions, so a recovered instance is indistinguishable
  # from one the watch pass released.
  defp restoring_orphans do
    Instance
    |> Ash.Query.filter(status == :restoring)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&active_run?/1)
  end

  # Still the watch pass's row: it will release the instance itself, in
  # this pass or the next. One active run per instance is the index's
  # invariant, so this is a plain existence check.
  defp active_run?(instance) do
    BackupRun
    |> Ash.Query.filter(instance_id == ^instance.id and status in [:pending, :running])
    |> Ash.exists?(authorize?: false)
  end

  defp safe_recover(instance, now) do
    recover(instance, now)
  rescue
    exception ->
      Logger.error(
        "Backup restore recovery failed for #{instance.id}: #{Exception.message(exception)}"
      )

      {:error, exception}
  end

  # The latest restore run decides what the crashed pass would have done.
  # A row that is not terminal yet is the watch pass's (active_run?/1 just
  # filtered those out, so this is defence against a racing finalize): the
  # next pass re-decides.
  defp recover(instance, now) do
    case latest_restore(instance) do
      %BackupRun{status: :succeeded} = run ->
        run
        |> release_instance(instance, now)
        |> recovered(instance)

      %BackupRun{status: :failed} ->
        instance
        |> land_failed_restore()
        |> recovered(instance)

      _none_or_active ->
        {:ok, nil}
    end
  end

  defp latest_restore(instance) do
    BackupRun
    |> Ash.Query.filter(instance_id == ^instance.id and kind == :restore)
    |> Ash.Query.sort(started_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:instance)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp recovered({:ok, _released}, instance), do: {:ok, {:recovered, instance.id}}

  # coveralls-ignore-start - defensive: the release arms normalize to
  # :ok (a failed rescale lands :error through restore_failed, which is
  # itself a write, not an error return). Only a DB outage surfaces
  # here, and ExUnit cannot stage one.
  defp recovered({:error, _error} = error, _instance), do: error
  # coveralls-ignore-stop

  # --- shared ----------------------------------------------------------

  defp summarize(results) do
    entries = for {:ok, entry} <- results, not is_nil(entry), do: entry

    %__MODULE__{
      started_ids: collect(entries, :started),
      succeeded_ids: collect(entries, :succeeded),
      failed_ids: collect(entries, :failed),
      recovered_ids: collect(entries, :recovered)
    }
  end

  defp collect(entries, kind) do
    for {^kind, id} <- entries, do: id
  end

  defp schedule_hour do
    Application.fetch_env!(:flux_vale, :backups)[:schedule_hour]
  end

  defp stale_after_seconds do
    Application.fetch_env!(:flux_vale, :backups)[:stale_after_seconds]
  end
end
