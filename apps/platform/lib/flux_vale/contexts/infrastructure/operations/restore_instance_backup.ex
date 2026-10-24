defmodule FluxVale.Infrastructure.Operations.RestoreInstanceBackup do
  @moduledoc """
  Restores a snapshot back into the same Instance (#222, ADR-0037 §5).

  **Same-instance only** (restore-to-new is the ADR's named next slice).
  The owner's explicit intent arrives as the UI's confirmation — this
  operation just runs; it re-checks only what could have changed between
  the click and the call.

  ## Flow

  1. **Guards** — each cheap and local, no cluster write before all pass:
     the settings row exists and is `enabled`, a `:succeeded` run with a
     `snapshot_id` exists (nothing to restore otherwise), no run is
     `:pending`/`:running` (a restore in flight must not butt heads with a
     backup, or another restore — restic's repo locks and the single PVC
     make that counterproductive), and the instance is deployed.
  2. **Hold the instance** — the `BackupRun` row lands in `:pending` with
     `kind: :restore` and `restored_from` set to the status found, *then*
     the status flips to `:restoring`. The row before the flip, the flip
     before the Job: a crash at any point leaves a `:pending` row the
     sweep's stale horizon closes, never an unwatched Job on a live
     instance.
  3. **Stop the app** — a running Deployment scales to 0 (the
     `StopInstance` mechanics, written here rather than reused: that
     operation lands `:stopped`, and the restore must keep its own
     intermediate state). `:stopped`/`:sleeping` rows are already at 0.
  4. **Apply the restore Job** — delete-tolerantly-then-create (Jobs are
     immutable).
  5. **The sweep finalizes** — `Operations.SweepBackups`'s watch pass reads
     the Job's verdict: success scales back to 1 and lands `:starting` when
     the app was running (`:stopped`/`:sleeping` go back untouched, no
     wake); failure lands `:error` with `:restore_failed`.

  ## Why `:restoring` (a status) and not just the run row

  The active-run guard alone would cover the sweep's own re-entry, but the
  status is the *user-visible* claim — the instance page says "Restoring",
  the edge's other-status arm answers 503 instead of waking, and
  `StartInstance`'s status guard no-ops. It is also what the reconciler
  leaves alone: its trigger selects only `[:deploying, :starting,
  :running]`, so a restore's half-written volume is never mirrored into
  `:running` or demoted mid-restore.

  ## The scale-down failure

  If the scale-to-zero fails, nothing has been written: the run row is
  settled `:failed` immediately (no stale slot) and the instance lands
  `:error` with `:restore_failed` — the same honest shape as a failed Job,
  and the app is still the app it was. Scaling back *up* is never attempted
  for a restore that never started.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Ash.Query
  require OpenTelemetry.Tracer

  # The statuses a restore can start from: each already has a volume at
  # rest (running is scaled down first). Together with StatusTransition's
  # own edges, these are the only legal entry points.
  @restorable_statuses [:running, :stopped, :sleeping]

  @doc """
  Restores the instance's most recent successful snapshot.

  `{:ok, run}` once the Job applied (`:pending`/`:running` — the sweep
  owns the outcome); `{:error, reason}` otherwise. Reasons name the guard
  that closed (`:no_settings`, `:backups_disabled`, `:nothing_to_restore`,
  `:run_in_flight`, `:not_deployed`, `:not_restorable`) or carry the K8s
  error.
  """
  @spec call(Instance.t()) :: {:ok, BackupRun.t()} | {:error, term()}
  def call(%Instance{} = instance) do
    OpenTelemetry.Tracer.with_span "instance.restore", span_attrs(instance) do
      restore(instance)
    end
  end

  defp span_attrs(instance) do
    %{
      attributes: %{
        "instance.id" => instance.id,
        "instance.slug" => instance.slug,
        "instance.namespace" => instance.namespace,
        "instance.status" => Atom.to_string(instance.status)
      }
    }
  end

  defp restore(instance) do
    case guards(instance) do
      {:ok, snapshot_id} -> start(instance, snapshot_id)
      {:error, _reason} = error -> error
    end
  end

  # System reads (authorize?: false): the operation reached here through
  # the UI's authorized instance read — the lifecycle ops' posture.
  # One-active-run is NOT a guard here (same stance as
  # RunInstanceBackup's): the partial unique index is the enforcement,
  # and `translate_taken_slot/1` renders its rejection as
  # `:run_in_flight` — this covers restore-over-backup and
  # restore-over-restore alike.
  defp guards(instance) do
    with :ok <- restorable(instance),
         :ok <- enabled_setting(instance),
         {:ok, snapshot_id} <- restorable_snapshot(instance),
         :ok <- deployed(instance) do
      {:ok, snapshot_id}
    end
  end

  # The status check comes first: it is the cheapest way to refuse a
  # restore on a row that is mid-deploy or gone, before any table read.
  # The second clause is the failed-restore retry (ADR-0037 §5): a row
  # that landed `:error` + `:restore_failed` is restorable again — the
  # app is already scaled down (a partial volume must not be served),
  # and the retry is the owner's way out. No other `:error` is.
  defp restorable(%{status: status}) when status in @restorable_statuses, do: :ok

  defp restorable(%{status: :error, failure_reason: :restore_failed}), do: :ok

  defp restorable(_instance), do: {:error, :not_restorable}

  defp enabled_setting(instance) do
    case BackupSetting.get_by_instance(instance.id, authorize?: false) do
      {:ok, %BackupSetting{enabled: true}} ->
        :ok

      {:ok, %BackupSetting{enabled: false}} ->
        {:error, :backups_disabled}

      # A missing row is `Ash.Error.Invalid` wrapping NotFound — the
      # settings resource's get shape.
      {:error, %Ash.Error.Invalid{}} ->
        {:error, :no_settings}

      # coveralls-ignore-start - defensive: the only other read failure is
      # a DB outage, which ExUnit cannot simulate (DBConnection reconnects
      # — the repo's cluster-level stance).
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The newest succeeded backup with a snapshot id. A succeeded row
  # without one cannot happen through the sweep (it fails such a run), but
  # the filter keeps the guard honest against a hand-edited row.
  defp restorable_snapshot(instance) do
    newest =
      BackupRun
      |> Ash.Query.filter(
        instance_id == ^instance.id and kind in [:scheduled, :manual] and
          status == :succeeded and not is_nil(snapshot_id)
      )
      |> Ash.Query.sort(started_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case newest do
      [%BackupRun{snapshot_id: snapshot_id}] -> {:ok, snapshot_id}
      [] -> {:error, :nothing_to_restore}
    end
  end

  # Both kinds: a restore in flight blocks a new backup AND a new restore
  # (ADR-0037 §1's single-writer stance — one Job per instance, whoever
  # started it).
  defp deployed(%{namespace: nil}), do: {:error, :not_deployed}
  defp deployed(%{namespace: _namespace}), do: :ok

  defp start(instance, snapshot_id) do
    prior = pre_restore_status(instance)

    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, run} <- create_run(instance, prior),
         {:ok, restoring} <- enter_restoring(instance) do
      apply_job(run, restoring, kubeconfig, snapshot_id, prior)
    end
  end

  # A first restore's target state is the row's own status; a RETRY
  # (from :error + :restore_failed) must return the instance to its
  # pre-FIRST-restore state, which the failed run recorded — the :error
  # row itself says nothing about where the app used to run.
  # Defensive fallback :stopped — never wakes an app on a guess.
  defp pre_restore_status(%{status: :error, failure_reason: :restore_failed} = instance) do
    prior_run =
      BackupRun
      |> Ash.Query.filter(
        instance_id == ^instance.id and kind == :restore and
          status == :failed
      )
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    Map.get(prior_run || %{}, :restored_from, :stopped)
  end

  defp pre_restore_status(%{status: status}), do: status

  defp create_run(instance, prior) do
    BackupRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        kind: :restore,
        status: :pending,
        started_at: DateTime.utc_now(),
        # The inherited prior (not instance.status): a retry's row must
        # record where the app ran before the FIRST restore, so the
        # success path returns it there (ADR-0037 §5).
        restored_from: prior
      },
      authorize?: false
    )
    |> Ash.create()
    |> translate_taken_slot()
  end

  # The partial unique index (one active run per instance) is the
  # invariant's teeth — the advisory guard can lose a race to a sweep,
  # the insert cannot. Same translation as RunInstanceBackup's (each
  # operation owns its helpers — the repo's boundary rule).
  defp translate_taken_slot(
         {:error,
          %Ash.Error.Invalid{
            errors: [
              %Ash.Error.Changes.InvalidAttribute{
                private_vars: [
                  {:constraint, "backup_runs_one_active_per_instance_index"} | _other_vars
                ]
              }
            ]
          }}
       ) do
    {:error, :run_in_flight}
  end

  defp translate_taken_slot(other), do: other

  # The status write funnels through InstanceK8s.update_status — the
  # repo's rule for deliberate operations (StopInstance's :stopped is the
  # precedent).
  defp enter_restoring(instance) do
    InstanceK8s.update_status(instance, :restoring, "Restoring a backup…")
  end

  defp apply_job(run, instance, kubeconfig, snapshot_id, prior) do
    outcome =
      with :ok <- stop_app(prior, instance, kubeconfig),
           :ok <- delete_leftover_job(kubeconfig, instance.namespace) do
        RestoreJob.create(kubeconfig, instance.namespace, job_spec(instance, snapshot_id))
      end

    case outcome do
      {:ok, _job} -> mark_running(run)
      {:error, _error} = error -> fail_now(run, instance, error)
    end
  end

  # A restore owns the instance: the app must not be writing the volume
  # while restic rewrites it. The PRE-restore status decides — by now the
  # row reads :restoring, so reading it here would never scale anything.
  # :stopped/:sleeping are already at 0: scaling them would be a pointless
  # write.
  defp stop_app(:running, instance, kubeconfig) do
    case Deployment.scale(kubeconfig, instance.namespace, "app", 0) do
      {:ok, _deployment} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp stop_app(_prior, _instance, _kubeconfig), do: :ok

  defp delete_leftover_job(kubeconfig, namespace) do
    case RestoreJob.delete(kubeconfig, namespace) do
      :ok -> :ok
      {:error, %Error{reason: :not_found}} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp job_spec(instance, snapshot_id) do
    %{
      slug: instance.slug,
      mount_path: instance.storage_mount_path,
      snapshot_id: snapshot_id
    }
  end

  # The row already exists, so a failed apply must not leave it :pending
  # for the stale horizon: the owner sees the failure now, and the run
  # slot frees for the retry. The instance lands :error too — unlike a
  # backup, a restore has taken the instance out of service (or was about
  # to), so there is no "the app keeps running" to fall back to.
  defp fail_now(run, instance, {:error, error}) do
    {:ok, _failed} =
      run
      |> Ash.Changeset.for_update(
        :update,
        %{
          status: :failed,
          error_summary: "restore job could not be applied: #{InstanceK8s.format_error(error)}",
          finished_at: DateTime.utc_now()
        },
        authorize?: false
      )
      |> Ash.update()

    InstanceK8s.update_status(
      instance,
      :error,
      "Restore failed: #{InstanceK8s.format_error(error)}",
      :restore_failed
    )

    {:error, error}
  end

  defp mark_running(run) do
    run
    |> Ash.Changeset.for_update(:update, %{status: :running}, authorize?: false)
    |> Ash.update()
  end
end
