defmodule FluxVale.Infrastructure.Operations.RunInstanceBackup do
  @moduledoc """
  Starts one instance backup (#222, ADR-0037 §3): guard, create the
  `BackupRun` row in `:pending`, replace the k8s Job, flip the row to
  `:running`.

  **One code path for both kinds.** The due pass (`kind: :scheduled`) and
  the owner's "Back up now" (`kind: :manual`) differ in the row's `kind`
  and nothing else — schedule drift between the two would be a bug, not a
  feature.

  Guards, in order (each one cheap and local — no cluster writes before
  all of them pass):

  - the instance has a settings row and it is `enabled` — a disabled
    instance never runs, manual or not (the owner's switch means what it
    says)
  - the instance has a namespace — a never-deployed instance has no PVC
    to read

  The one-active-run invariant is NOT a guard: the partial unique index
  over `pending`/`running` rows is the enforcement (atomic under
  concurrency — a sweep racing a manual click loses its insert), and
  the index's rejection is translated to `:run_in_flight`, which the
  sweep treats as benign and the UI as "a run is already going".

  Order of the writes matters, twice over: the previous run's Job is
  deleted **before** the new row exists (a `:pending` row must never be
  able to read the previous run's Job and absorb its outcome), and the
  row lands **before** the new Job applies, so a crash between the two
  leaves a `:pending` row the watch pass's stale horizon cleans up,
  never an unwatched Job. The Job carries the run's id as a label —
  the sweep's ownership check — so even a leftover Job can never be
  attributed to the wrong row.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Logger
  require OpenTelemetry.Tracer

  # The whole orchestration is one `instance.backup` span (ADR-0012
  # Am. 1's shape for deploy/reconcile): the sweep's decision → apply →
  # row state is the trace an operator needs when a backup misbehaves.
  @doc """
  Runs a backup for `instance`. `{:ok, run}` when the Job applied;
  `{:error, reason}` otherwise — the reason names the guard that closed
  (`:backups_disabled`, `:no_settings`, `:run_in_flight`, `:not_deployed`)
  or carries the K8s error.
  """
  @spec call(Instance.t(), :scheduled | :manual) ::
          {:ok, BackupRun.t()} | {:error, term()}
  def call(%Instance{} = instance, kind) when kind in [:scheduled, :manual] do
    OpenTelemetry.Tracer.with_span "instance.backup", span_attrs(instance, kind) do
      run(instance, kind)
    end
  end

  defp span_attrs(instance, kind) do
    %{
      attributes: %{
        "instance.id" => instance.id,
        "instance.slug" => instance.slug,
        "instance.namespace" => instance.namespace,
        "backup.kind" => Atom.to_string(kind)
      }
    }
  end

  defp run(instance, kind) do
    case guards(instance) do
      {:ok, setting} -> start(instance, setting, kind)
      {:error, _reason} = error -> error
    end
  end

  # System reads (authorize?: false): the sweep runs actorless, and the UI's
  # manual trigger reached this operation through the authorized
  # `Instance.get_by_id` — the same ownership posture as the lifecycle ops.
  # One-active-run is NOT a guard here: the partial unique index on
  # backup_runs is the enforcement (atomic under concurrency — ADR-0037
  # §3), and `translate_taken_slot/1` renders its rejection as
  # `:run_in_flight`.
  defp guards(instance) do
    with {:ok, setting} <- enabled_setting(instance),
         :ok <- deployed(instance) do
      {:ok, setting}
    end
  end

  defp enabled_setting(instance) do
    case BackupSetting.get_by_instance(instance.id, authorize?: false) do
      {:ok, %BackupSetting{enabled: true} = setting} ->
        {:ok, setting}

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

  defp deployed(%{namespace: nil}), do: {:error, :not_deployed}
  defp deployed(%{namespace: _namespace}), do: :ok

  # Delete-before-insert (review finding): the leftover Job must be GONE
  # before the new row exists, or a concurrent watch pass can read the
  # previous run's Job and finalize the brand-new row with its verdict.
  defp start(instance, setting, kind) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         :ok <- delete_leftover_job(kubeconfig, instance.namespace),
         {:ok, run} <- create_run(instance, kind) do
      apply_job(run, kubeconfig, instance, setting)
    end
  end

  defp create_run(instance, kind) do
    BackupRun
    |> Ash.Changeset.for_create(
      :create,
      %{instance_id: instance.id, kind: kind, status: :pending, started_at: DateTime.utc_now()},
      authorize?: false
    )
    |> Ash.create()
    |> translate_taken_slot()
  end

  # The partial unique index is the one-active-run invariant's teeth
  # (ADR-0037 §3): the `no_run_in_flight` guard is advisory (a sweep can
  # race a manual click between its check and this insert), the index is
  # atomic — the loser lands here and reads as the same benign
  # `:run_in_flight` the guard returns, never as a crash.
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

  defp apply_job(run, kubeconfig, instance, setting) do
    case BackupJob.create(kubeconfig, instance.namespace, job_spec(run, instance, setting)) do
      {:ok, _job} -> mark_running(run)
      {:error, _error} = error -> fail_now(run, error)
    end
  end

  # The row already exists, so a failed apply must not leave it `:pending`
  # for the stale horizon to find two hours later: the owner gets the
  # failure straight away, and the run slot is free for the retry. The
  # summary is truncated BEFORE the write (the attribute caps at 500 —
  # an over-long admission/quota message must fail the run, not the
  # write), and a failed finalize write is logged, never raised: a
  # MatchError here would escape the operation and crash the caller
  # (review finding).
  defp fail_now(run, {:error, error}) do
    summary =
      truncate("backup job could not be applied: #{InstanceK8s.format_error(error)}")

    finalize =
      run
      |> Ash.Changeset.for_update(
        :update,
        %{status: :failed, error_summary: summary, finished_at: DateTime.utc_now()},
        authorize?: false
      )
      |> Ash.update()

    case finalize do
      {:ok, _failed} ->
        :ok

      # coveralls-ignore-start - defensive: the row was readable a
      # moment ago; only a concurrent finalize or a DB outage lands
      # here, and ExUnit can stage neither deterministically.
      {:error, _write_error} = write_error ->
        Logger.warning("Backup run #{run.id} could not settle :failed: #{inspect(write_error)}")
        # coveralls-ignore-stop
    end

    {:error, error}
  end

  # The sweep's own truncate stance: a long reason never fails the write
  # itself.
  defp truncate(text) do
    String.slice(text, 0, 500)
  end

  # Jobs are immutable, so the previous run's object must go first.
  defp delete_leftover_job(kubeconfig, namespace) do
    case BackupJob.delete(kubeconfig, namespace) do
      :ok -> :ok
      {:error, %Error{reason: :not_found}} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp job_spec(run, instance, setting) do
    %{
      slug: instance.slug,
      mount_path: instance.storage_mount_path,
      keep_last: setting.retention_keep,
      run_id: run.id
    }
  end

  defp mark_running(run) do
    run
    |> Ash.Changeset.for_update(:update, %{status: :running}, authorize?: false)
    |> Ash.update()
  end
end
