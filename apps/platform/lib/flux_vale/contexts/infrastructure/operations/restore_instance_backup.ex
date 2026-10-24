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
     **Then wait for the pods to be gone**: `scale` returns when the API
     accepts the count, and restic's `--delete` must never run against a
     live writer.
  4. **Apply the restore Job** — both leftover Jobs (the backup run's and
     a previous restore's) deleted tolerantly, each awaited gone, then
     create.
  5. **The sweep finalizes** — `Operations.SweepBackups`'s watch pass reads
     the Job's verdict: success scales back to 1 and lands `:starting` when
     the app was running (`:stopped`/`:sleeping` go back untouched, no
     wake); failure lands `:error` with `:restore_failed`.

  ## Ownership (#222 review)

  `opts` carry the caller's `actor:` — the instance is re-read through
  the authorized `get_by_id`, so an outsider is `Forbidden` before any
  cluster write (the ConfigureBackups shape). A caller with **no** actor
  is the system (the sweep's recovery arm, seed/bootstrap paths): its
  reads and writes run `authorize?: false`, the lifecycle posture — the
  actor, when present, is always the one that authorizes.

  ## Failure before the Job: the app was never touched

  A failure after the run row exists but *before* the restore Job applies
  writes nothing to the volume, so it is the run's failure, not the
  instance's: the row settles `:failed` with an honest summary, the
  instance returns to the status it was found in, and it does **not**
  land `:error`/`:restore_failed`. The retry therefore re-enters through
  the normal restorable guard — no special retry arm, and no false
  "partly restored" copy about a volume restic never opened.

  The revert is state-aware: an instance still in its prior status (the
  `:restoring` flip itself failed) needs no revert at all; one the
  operation already holds goes back to `:starting`-plus-scale-1 when it
  was running, or to `:stopped`/`:sleeping` untouched when it was parked.

  ## Why `:restoring` (a status) and not just the run row

  The active-run guard alone would cover the sweep's own re-entry, but the
  status is the *user-visible* claim — the instance page says "Restoring",
  the edge's restoring arm answers 503 instead of waking, and
  `StartInstance`'s status guard no-ops. It is also what the reconciler
  leaves alone: its trigger selects only `[:deploying, :starting,
  :running]`, so a restore's half-written volume is never mirrored into
  `:running` or demoted mid-restore.

  The status is also why the sweep carries a crash-recovery arm
  (`SweepBackups`'s third pass): a crash between the sweep's finalize and
  its release would otherwise strand `:restoring` with no active run for
  any pass to revisit.
  """

  # The `get_by_id` failure shapes are structural, not semantic: a
  # missing row and a filtered-out row both arrive as this class.
  alias Ash.Error.Forbidden
  alias Ash.Error.Forbidden.Policy
  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Ash.Query
  require Logger
  require OpenTelemetry.Tracer

  # The statuses a restore can start from: each already has a volume at
  # rest (running is scaled down first). Together with StatusTransition's
  # own edges, these are the only legal entry points.
  @restorable_statuses [:running, :stopped, :sleeping]

  @forbidden_message "This instance belongs to another organization"

  # How often the scale-down wait re-reads the Deployment. Clamped to the
  # pass's own budget (see poll_interval/2) so a short wait never sleeps
  # past its deadline — and a test can pin a small budget without the
  # suite paying the production interval.
  @scale_down_poll_ms 5_000
  @job_delete_poll_ms 500

  @doc """
  Restores the instance's most recent successful snapshot.

  `{:ok, run}` once the Job applied (`:pending`/`:running` — the sweep
  owns the outcome); `{:error, reason}` otherwise. Reasons name the guard
  that closed (`:no_settings`, `:backups_disabled`, `:nothing_to_restore`,
  `:run_in_flight`, `:not_deployed`, `:not_restorable`), the ownership
  refusal (`Forbidden`), or carry the K8s error.
  """
  @spec call(Instance.t(), keyword()) :: {:ok, BackupRun.t()} | {:error, term()}
  def call(%Instance{} = instance, opts \\ []) do
    opts = actor_authorized(opts)

    OpenTelemetry.Tracer.with_span "instance.restore", span_attrs(instance) do
      case authorize_instance(instance, opts) do
        {:ok, authorized} -> restore(authorized)
        {:error, _reason} = error -> error
      end
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

  # An actor always authorizes (the ConfigureBackups shape): a caller
  # can't pair a stranger's actor with `authorize?: false` and a hoisted
  # instance struct to slip past the ownership read. A caller with NO
  # actor is the system — reads and writes run the lifecycle posture's
  # `authorize?: false`.
  defp actor_authorized(opts) do
    cond do
      opts[:actor] -> Keyword.delete(opts, :authorize?)
      Keyword.has_key?(opts, :authorize?) -> opts
      true -> Keyword.put(opts, :authorize?, false)
    end
  end

  # Ownership first, and a write answers Forbidden where a read would
  # merely filter: a stranger's restore must not read as "not found" —
  # and must never reach the cluster. The unauthorized re-read only tells
  # "not yours" apart from "gone" on the failure path.
  defp authorize_instance(instance, opts) do
    case Instance.get_by_id(instance.id, opts) do
      {:ok, authorized} ->
        {:ok, authorized}

      {:error, %Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%NotFound{}, &1)) do
          not_owned_or_missing(instance, opts)
        else
          {:error, error}
        end

      # coveralls-ignore-start - defensive: the only other read failure is
      # a DB outage, which ExUnit cannot simulate (DBConnection reconnects)
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp not_owned_or_missing(instance, opts) do
    case Instance.get_by_id(instance.id, Keyword.put(opts, :authorize?, false)) do
      {:ok, _existing} ->
        {:error, Forbidden.exception(errors: [forbidden_error()])}

      # coveralls-ignore-start - defensive: a row deleted between the two
      # reads is a race ExUnit can't stage deterministically; the plain
      # NotFound is the honest answer when it happens.
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The policy error is the one Ash would produce on the write, carrying a
  # plain-words reason instead of a bare "forbidden".
  defp forbidden_error do
    Policy.exception(custom_message: @forbidden_message)
  end

  defp restore(instance) do
    # The FOUND status (before the :restoring flip) rides the whole
    # flow: a RETRY (found :error + :restore_failed) entered with the
    # app already down over a possibly-partial volume, and its failure
    # path must land :error again, never restart the app (CodeRabbit:
    # a failed retry restarting on a partial volume contradicts the
    # module's own rule).
    found = instance.status

    case guards(instance) do
      {:ok, snapshot_id} -> start(instance, snapshot_id, found)
      {:error, _reason} = error -> error
    end
  end

  # System reads (authorize?: false): the operation reached here through
  # the ownership read above (or the system's explicit bypass).
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

  defp start(instance, snapshot_id, found) do
    prior = pre_restore_status(instance)

    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      case create_run(instance, prior) do
        {:ok, run} -> run_restore(run, instance, kubeconfig, snapshot_id, prior, found)
        {:error, _reason} = error -> error
      end
    end
  end

  # A first restore's target state is the row's own status; a RETRY
  # (from :error + :restore_failed) must return the instance to its
  # pre-FIRST-restore state, which the failed run recorded — the :error
  # row itself says nothing about where the app used to run.
  defp pre_restore_status(%{status: :error, failure_reason: :restore_failed} = instance) do
    prior_run =
      BackupRun
      |> Ash.Query.filter(
        instance_id == ^instance.id and kind == :restore and
          status == :failed
      )
      |> Ash.Query.sort(started_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    # `restored_from` is nullable, so Map.get's default would never fire
    # on the key being present-and-nil — a successful retry would then
    # fail :unknown_prior_status in the sweep. Never wake on a guess.
    case prior_run do
      nil -> :stopped
      run -> run.restored_from || :stopped
    end
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

  # The row exists from here on: every failure — the :restoring flip, the
  # scale-down, the leftover-Job deletes, the create — settles it and
  # returns the instance to where it was found. Nothing has touched the
  # volume yet, so the instance never lands :error.
  defp run_restore(run, instance, kubeconfig, snapshot_id, prior, found) do
    case enter_restoring(instance) do
      {:ok, restoring} ->
        hold_and_apply(run, restoring, kubeconfig, snapshot_id, prior, found)

      # The flip failed, so the instance never left its prior status:
      # only the row needs settling.
      {:error, _error} = error ->
        abandon(run, instance, prior, found, error)
    end
  end

  defp hold_and_apply(run, restoring, kubeconfig, snapshot_id, prior, found) do
    outcome =
      with :ok <- stop_app(prior, restoring, kubeconfig),
           :ok <- delete_leftover_jobs(kubeconfig, restoring.namespace) do
        RestoreJob.create(kubeconfig, restoring.namespace, job_spec(run, restoring, snapshot_id))
      end

    case outcome do
      {:ok, _job} -> mark_running(run)
      {:error, _error} = error -> abandon(run, restoring, prior, found, error)
    end
  end

  # The status write funnels through InstanceK8s.update_status — the
  # repo's rule for deliberate operations (StopInstance's :stopped is the
  # precedent). failure_reason is explicit nil: a restore's hold is not a
  # failure, and the four-arity form is the funnel's one seam.
  defp enter_restoring(instance) do
    InstanceK8s.update_status(instance, :restoring, "Restoring a backup…", nil)
  end

  # A restore owns the instance: the app must not be writing the volume
  # while restic rewrites it. The PRE-restore status decides — by now the
  # row reads :restoring, so reading it here would never scale anything.
  # :stopped/:sleeping are already at 0: scaling them would be a pointless
  # write.
  defp stop_app(:running, instance, kubeconfig) do
    with {:ok, _deployment} <- Deployment.scale(kubeconfig, instance.namespace, "app", 0) do
      await_termination(kubeconfig, instance.namespace)
    end
  end

  defp stop_app(_prior, _instance, _kubeconfig), do: :ok

  # `scale` returns when the API accepts the desired count — the pods are
  # still running (and, with a `terminationGracePeriodSeconds`, still
  # writing) for a while after. restic's `--delete` against a live writer
  # is exactly the corruption this restore exists to avoid, so the Job is
  # not applied until the Deployment reports zero replicas.
  defp await_termination(kubeconfig, namespace) do
    timeout_ms = scale_down_timeout_ms()

    poll_terminated(
      kubeconfig,
      namespace,
      deadline(timeout_ms),
      poll_interval(@scale_down_poll_ms, timeout_ms)
    )
  end

  # Polling an external resource, not a process — Process.sleep is the tool
  # (the Deployment.wait_for_ready precedent).
  defp poll_terminated(kubeconfig, namespace, deadline, interval) do
    case Deployment.get(kubeconfig, namespace, "app") do
      {:ok, deployment} ->
        cond do
          terminated?(deployment) ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            {:error,
             Error.timeout(
               "could not stop the app: pods are still running after " <>
                 "#{scale_down_timeout_ms()}s"
             )}

          true ->
            Process.sleep(interval)
            poll_terminated(kubeconfig, namespace, deadline, interval)
        end

      # No Deployment: nothing is serving the volume (a namespace whose app
      # never landed, or one an operator removed) — as stopped as it gets.
      {:error, %Error{reason: :not_found}} ->
        :ok

      {:error, _error} = error ->
        error
    end
  end

  # Both counters nil-or-0: the controller has rolled every pod down. A
  # Deployment object that was never scaled shows no `status.replicas` at
  # all — nil reads as zero, the same stance as Deployment.status/3.
  defp terminated?(deployment) do
    status = deployment["status"] || %{}

    zero?(status["replicas"]) and zero?(status["readyReplicas"])
  end

  defp zero?(nil), do: true
  defp zero?(0), do: true
  defp zero?(_count), do: false

  # The one-active-run index guarantees no legitimate backup Job is in
  # flight, so BOTH fixed-name Jobs are leftovers: a zombie backup run's
  # restic lock would otherwise fail every restore (exit 11). Each delete
  # is tolerant, and each waits for the object to actually go — an SSA
  # onto a still-terminating Job 4xxs.
  defp delete_leftover_jobs(kubeconfig, namespace) do
    with :ok <- delete_and_await(BackupJob, kubeconfig, namespace) do
      delete_and_await(RestoreJob, kubeconfig, namespace)
    end
  end

  defp delete_and_await(job_module, kubeconfig, namespace) do
    case job_module.delete(kubeconfig, namespace) do
      :ok -> await_job_gone(job_module, kubeconfig, namespace)
      {:error, %Error{reason: :not_found}} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp await_job_gone(job_module, kubeconfig, namespace) do
    timeout_ms = job_delete_timeout_ms()

    poll_job_gone(
      job_module,
      kubeconfig,
      namespace,
      deadline(timeout_ms),
      poll_interval(@job_delete_poll_ms, timeout_ms)
    )
  end

  defp poll_job_gone(job_module, kubeconfig, namespace, deadline, interval) do
    case job_module.get(kubeconfig, namespace) do
      {:error, %Error{reason: :not_found}} ->
        :ok

      {:ok, _still_there} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error,
           Error.timeout(
             "leftover #{job_module.name()} job did not go away after " <>
               "#{div(job_delete_timeout_ms(), 1_000)}s"
           )}
        else
          Process.sleep(interval)
          poll_job_gone(job_module, kubeconfig, namespace, deadline, interval)
        end

      {:error, _error} = error ->
        error
    end
  end

  defp job_spec(run, instance, snapshot_id) do
    %{
      slug: instance.slug,
      mount_path: instance.storage_mount_path,
      snapshot_id: snapshot_id,
      run_id: run.id
    }
  end

  # The row already exists, so a failed start must not leave it :pending
  # for the stale horizon: the owner sees the failure now, and the run
  # slot frees for the retry. The FOUND status decides the instance's
  # fate: a FIRST restore found the app up and nothing has touched the
  # volume yet — the instance goes back to where it was found and the
  # failure is the run's story, not the app's. A RETRY found :error +
  # :restore_failed — the app is down over a possibly-partial volume
  # from the first attempt, and restarting it would serve that volume;
  # the row lands :error/:restore_failed again, down it stays.
  defp abandon(run, instance, prior, found, {:error, error}) do
    case found do
      :error ->
        summary =
          "restore could not start again: #{InstanceK8s.format_error(error)}; " <>
            "your data may still be partly restored"

        settle_failed(run, summary)
        land_failed_restore(instance)

      _first_restore ->
        summary =
          "restore could not start: #{InstanceK8s.format_error(error)}; the app is unchanged"

        settle_failed(run, summary)
        revert(instance, prior)
    end

    {:error, error}
  end

  # The retry's honest end state: still :error, still :restore_failed —
  # the copy the failure surface shows already tells the owner to try
  # again.
  defp land_failed_restore(instance) do
    InstanceK8s.update_status(
      instance,
      :error,
      "Restore failed; the volume may be in a partially restored state",
      :restore_failed
    )
  end

  # The summary is truncated BEFORE the write (the attribute caps at 500 —
  # an over-long admission/API message must fail the run, not the write),
  # and a failed settle is logged, never raised: a MatchError here would
  # escape the operation and crash the caller with the original failure
  # already in hand.
  defp settle_failed(run, summary) do
    finalize =
      run
      |> Ash.Changeset.for_update(
        :update,
        %{status: :failed, error_summary: truncate(summary), finished_at: DateTime.utc_now()},
        authorize?: false
      )
      |> Ash.update()

    case finalize do
      {:ok, _failed} ->
        :ok

      # coveralls-ignore-start - defensive: the row was readable a moment
      # ago; only a concurrent finalize or a DB outage lands here, and
      # ExUnit can stage neither deterministically.
      {:error, _write_error} = write_error ->
        Logger.warning("Restore run #{run.id} could not settle :failed: #{inspect(write_error)}")
        # coveralls-ignore-stop
    end
  end

  # The instance never left its prior status (the :restoring write itself
  # failed): already where it belongs, and touching it would invent a
  # transition the state machine refuses (`:running` cannot go to
  # `:starting`).
  defp revert(%Instance{status: :restoring} = instance, :running), do: restart_app(instance)

  defp revert(%Instance{status: :restoring} = instance, prior)
       when prior in [:stopped, :sleeping] do
    instance
    |> InstanceK8s.update_status(prior, revert_message(prior))
    |> revert_outcome()
  end

  defp revert(instance, _prior), do: instance

  # The scale-down was not attempted (or did not land), so the desired
  # count is still 1: re-asserting it is a no-op write, and :starting is
  # the honest status — the reconciler re-confirms readiness and stays
  # the only writer of :running.
  defp restart_app(instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, _deployment} <- Deployment.scale(kubeconfig, instance.namespace, "app", 1) do
      instance
      |> InstanceK8s.update_status(:starting, "Starting; awaiting readiness")
      |> revert_outcome()
    else
      # A running app the platform could not put back into service: :error
      # is the honest state (a :starting row would claim a rollout that
      # never began, and the reconciler would mirror 0 replicas into it).
      {:error, error} -> restore_failed(instance, error)
    end
  end

  defp revert_message(:stopped), do: "Restore could not start; your app stays stopped"
  defp revert_message(:sleeping), do: "Restore could not start; your app stays asleep"

  defp restore_failed(instance, error) do
    instance
    |> InstanceK8s.update_status(
      :error,
      "Restore could not start and the app could not be returned to service: " <>
        InstanceK8s.format_error(error),
      :restore_failed
    )
    |> revert_outcome()
  end

  # Every revert arm's shape is {:ok, instance} | {:error, error}; the
  # caller only reports the original failure.
  defp revert_outcome({:ok, _instance}), do: :ok

  # The revert writes :error from any state and the status funnel only
  # fails on a DB outage, which ExUnit cannot stage (DBConnection
  # reconnects — the repo's cluster-level stance).
  # coveralls-ignore-next-line
  defp revert_outcome({:error, _error} = error), do: error

  defp mark_running(run) do
    run
    |> Ash.Changeset.for_update(:update, %{status: :running}, authorize?: false)
    |> Ash.update()
  end

  # The row's own 500-char limit is the contract; truncate so a long
  # admission/API message never fails the write itself.
  defp truncate(summary) when is_binary(summary), do: String.slice(summary, 0, 500)

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  # Never sleep past the budget: a short wait (a test's, or a 2s
  # configured one) polls at its own scale instead of the production
  # interval.
  defp poll_interval(interval_ms, timeout_ms), do: min(interval_ms, timeout_ms)

  defp scale_down_timeout_ms do
    Application.fetch_env!(:flux_vale, :backups)[:scale_down_timeout_seconds] * 1_000
  end

  defp job_delete_timeout_ms do
    Application.fetch_env!(:flux_vale, :backups)[:job_delete_timeout_seconds] * 1_000
  end
end
