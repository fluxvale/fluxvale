defmodule FluxVale.Infrastructure.Operations.SweepBackups do
  @moduledoc """
  The backup sweep (#222, ADR-0037 §3) — one Oban pass every five
  minutes, two passes per call:

  - **DUE**: instances with enabled settings whose daily window has
    opened and that have not started a run since it did →
    `RunInstanceBackup.call(instance, :scheduled)`.
  - **WATCH**: runs still `:pending`/`:running` → read the Job and
    finalize.

  `now` is a parameter, never `DateTime.utc_now/0` inside the arithmetic:
  the worker passes the clock, tests pass fixed instants, and the due
  window is a pure function of (instance, setting, now). No sleeping, no
  time-freezing.

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
  `RunInstanceBackup` (`:run_in_flight`, `:backups_disabled`) is not a
  failure — it is the sweep racing a manual run or an owner's toggle, and
  the next pass re-decides.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RunInstanceBackup

  require Ash.Query
  require Logger

  # Run guards that mean "someone else owns this decision right now" —
  # a manual run started, or the owner disabled backing up mid-pass.
  @benign_guards [:run_in_flight, :backups_disabled, :no_settings]

  @enforce_keys [:started_ids, :succeeded_ids, :failed_ids]
  defstruct [:started_ids, :succeeded_ids, :failed_ids]

  @type t :: %__MODULE__{
          started_ids: [Ash.UUID.t()],
          succeeded_ids: [Ash.UUID.t()],
          failed_ids: [Ash.UUID.t()]
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
    # fresh rows against a Job that has not scheduled yet.
    results =
      Enum.map(active_runs(), &safe_watch(&1, now)) ++
        Enum.map(due_instances(), &safe_due(&1, now))

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
    |> Ash.Query.filter(instance_id == ^instance.id and started_at >= ^opened)
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

  defp read_job(run, instance, now) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      case BackupJob.status(kubeconfig, instance.namespace) do
        {:ok, %{outcome: :succeeded} = outcome} -> settle_succeeded(run, outcome, now)
        {:ok, %{outcome: :failed} = outcome} -> settle_failed(run, outcome, now)
        {:ok, %{outcome: :running}} -> stale(run, now)
        {:error, %Error{reason: :not_found}} -> gone_or_stale(run, instance, kubeconfig, now)
        {:error, _error} = error -> error
      end
    end
  end

  # The ownership gate before any verdict write (see owned?/2); the
  # settle helpers keep read_job's case flat (credo's nesting rule).
  defp settle_succeeded(run, outcome, now) do
    if owned?(run, outcome), do: finish_succeeded(run, outcome, now), else: stale(run, now)
  end

  defp settle_failed(run, outcome, now) do
    if owned?(run, outcome),
      do: finish_failed(run, failure_text(outcome), now),
      else: stale(run, now)
  end

  # The fixed-name Job outlives its run (immutable objects, deleted only
  # at the next start): a verdict is only this row's if the Job's
  # run-id label names it. A mismatch is not an error — the row simply
  # keeps waiting (the next run's watch will settle it, or the stale
  # horizon does). A nil label is a pre-label Job: none exist outside a
  # single deploy, proceed (one-release backward compatibility).
  # Map.get, not dot access: the outcome map is our own builder's
  # shape in production, but a stub or an older build may omit the
  # key — dot access would raise and fail the whole pass.
  defp owned?(run, outcome) do
    run_id = Map.get(outcome, :run_id)
    is_nil(run_id) or run_id == run.id
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

  defp finish_succeeded(run, outcome, now) do
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
    finalize(run, %{
      status: :failed,
      error_summary: truncate(summary),
      finished_at: now
    })
  end

  defp finalize(run, attrs) do
    case run
         |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
         |> Ash.update() do
      {:ok, finished} ->
        tagged(finished.status, finished.id)

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

  # --- shared ----------------------------------------------------------

  defp summarize(results) do
    entries = for {:ok, entry} <- results, not is_nil(entry), do: entry

    %__MODULE__{
      started_ids: collect(entries, :started),
      succeeded_ids: collect(entries, :succeeded),
      failed_ids: collect(entries, :failed)
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
