defmodule FluxVale.Infrastructure.Operations.SweepStrandedInstances do
  @moduledoc """
  Drives stranded instances to a terminal state (#154) — the hourly
  sweeper behind `Workers.StrandedInstanceSweep`. Three arms, each
  taking only what nothing else converges (design settled on the issue):

  - **Stuck `:deleting`** — no live teardown job in `oban_jobs`. The
    job table is the lease: a lost, cancelled, or discarded job means
    destroy was decided but never ran (the #116 exit-run shape).
    `Instance.delete` can't self-heal it (its `:deleting` guard skips
    rows mid-teardown), so the sweep re-enqueues the teardown trigger —
    the same machinery a user retry drives. `:not_found`-tolerant
    deletes make a race with a straggler job harmless.
  - **Namespace gone, row alive** (#196) — accruing rows (`:running`/
    `:stopped`/`:sleeping`/`:restoring`/`:error` with
    `storage_metering_since` set) whose
    namespace 404s flip to `:lost`: metering parks atomically with the
    flip (MaintainAnchors), the row surfaces with re-deploy/teardown
    affordances, and the owner decides — the platform no longer
    silently destroys a row whose namespace an outside actor deleted
    (the Oct-21 incident kept accruing on a dead row for exactly this
    silence). `:stopped` is the worst leak the arm catches: outside the
    reconciler entirely, it would accrue storage forever. Never-ran
    `:error` rows accrue nothing and stay retryable; `:lost` rows are
    this arm's output, not input (no repeated flips). Only a definitive
    404 counts: kubeconfig or API failures skip the row, never strand
    it.
  - **Orphaned namespaces** — `fluxvale-app-<uuid>`-shaped, phase
    `Active`, **labeled with THIS platform's env** (#196), no matching
    row: deleted, with the row re-checked immediately before the
    destructive call (the live-id snapshot is stale by however long the
    pass's cluster reads took — a deploy landing mid-pass must not lose
    its fresh namespace, and an unreadable re-read protects the
    candidate and fails the pass). The env label is the Oct-21
    incident's lesson: staging and production share one physical
    cluster (ADR-0010) with a Cluster row each, so an unscoped sweep
    deleted another env's namespace for having no row in *this* DB —
    prod's pass deleted staging's running instance at 13:13. Only
    own-env labels are candidates; foreign-env and unlabeled
    namespaces (pre-#196 deploys, operator-placed) are never the
    sweep's to delete. `Terminating` is skipped — that's normal teardown
    GC (the row dies before the namespace finishes disappearing). A 404
    on the delete is the goal already achieved, not a failure.

  Complements, never fights: `:starting`/`:running` stay the
  reconciler's (it detects an externally-deleted namespace within a
  minute, `:lost` since #196; `:deploying` converges on its own
  stale-deploy timeout); this sweep is the backstop that also covers
  `:stopped`/`:error` rows the reconciler never reads. The #124 ladder
  keeps the only time-based destroy authority — this sweep is
  condition-based only, so races with the ladder converge (a live
  teardown job is a skip; a lost one gets re-driven to the same
  terminal state the ladder already decided; a `:lost` row the ladder
  destroys rides the normal teardown funnel).
  """

  import Ecto.Query, only: [where: 3]

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Repo

  require Logger

  # ADR-0005's namespace convention, strict enough to never match a
  # platform namespace (the RBAC SA namespace, the edge, ...).
  @instance_namespace_regex ~r/^fluxvale-app-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  # #196: the ownership label DeployInstance stamps from
  # config :platform_env — the orphan sweep's scope on the shared box.
  @env_label "fluxvale.io/platform-env"

  # The jobs table IS the lease: a teardown job in any of these states
  # means the row's destroy is still in flight. Cancelled/discarded
  # jobs are lapsed — re-drive. Must equal Oban's incomplete set (the
  # AshOban workers' `unique: [states: :incomplete]`): any state missed
  # here still dedupes the re-enqueue into a silent no-op.
  @incomplete_states Oban.Job.unique_states(:incomplete)
  @live_job_states Enum.map(@incomplete_states, &Atom.to_string/1)

  # Arm 2's candidates: statuses nothing else converges once the
  # namespace is gone. :running/:stopped carry the storage anchor by
  # construction; on :error the anchor check filters never-ran rows.
  # :sleeping (#203) joins them — it accrues on the same anchor and is
  # below the reconciler's trigger, so this sweep is its loss detector.
  # :restoring (#222) joins too: the reconciler never reads it, so a
  # namespace an outside actor deletes mid-restore would otherwise stay
  # :restoring forever with its storage accruing.
  @stranded_statuses [:running, :stopped, :sleeping, :error, :restoring]

  @lost_message "Namespace gone from cluster; marked lost (#196)"

  @enforce_keys [:requeued_teardown_ids, :lost_ids, :deleted_orphan_namespaces]
  defstruct [:requeued_teardown_ids, :lost_ids, :deleted_orphan_namespaces]

  @type t :: %__MODULE__{
          requeued_teardown_ids: [Ash.UUID.t()],
          lost_ids: [Ash.UUID.t()],
          deleted_orphan_namespaces: [String.t()]
        }

  @doc """
  One sweep pass over every instance and cluster. `{:ok, summary}` when
  every unit processed; `{:error, reason}` if any unit failed (one bad
  unit is logged and skipped, not allowed to eat the sweep — the
  ZeroBalanceSweep discipline; the caller's Oban retry owns recovery).
  """
  @spec call() :: {:ok, t()} | {:error, String.t()}
  def call do
    instances = Ash.read!(Instance, authorize?: false)
    live_ids = MapSet.new(instances, fn instance -> instance.id end)
    clusters = Ash.read!(Cluster, authorize?: false)

    results =
      Enum.map(instances, &safe_sweep_instance/1) ++
        Enum.map(clusters, fn cluster -> safe_sweep_cluster(cluster, live_ids) end)

    failure_count = Enum.count(results, &match?({:error, _reason}, &1))

    if failure_count == 0 do
      {:ok, summarize(results)}
    else
      {:error, "stranded-instance sweep failed for #{failure_count} unit(s)"}
    end
  end

  # Arm 1: the lease check. A :deleting row whose teardown job is gone
  # gets the destroy it was promised.
  defp sweep_instance(%{status: :deleting} = instance) do
    if teardown_job_live?(instance.id) do
      {:ok, nil}
    else
      Logger.warning(
        "Instance #{instance.id} is :deleting with no live teardown job; re-enqueueing teardown"
      )

      AshOban.run_trigger(instance, :teardown)

      {:ok, {:requeued_teardown, instance.id}}
    end
  end

  # Arm 2: an accruing row whose namespace is verifiably gone flips to
  # :lost — metering parks atomically (MaintainAnchors rides the
  # funnel), and the owner picks re-deploy or teardown from the UI.
  # Arm 3's discipline on the destructive write: the pass-start
  # snapshot is as old as the pass's cluster reads, so the row is
  # re-read immediately before the flip — a row that moved to
  # :deploying (retry) or :deleting (owner delete) mid-pass is not ours
  # to park, and a destroyed row must not be resurrected by the write.
  # The same-instant interleave remains last-write-wins (no row lock —
  # every status writer's stance) and converges through the funnel.
  defp sweep_instance(%{status: status} = instance) when status in @stranded_statuses do
    if accruing?(instance) and namespace_definitively_gone?(instance) and
         still_stranded?(instance) do
      Logger.warning("Instance #{instance.id}: namespace gone from cluster; marking :lost (#196)")

      {:ok, _lost} = InstanceK8s.update_status(instance, :lost, @lost_message)

      {:ok, {:lost, instance.id}}
    else
      {:ok, nil}
    end
  end

  # :pending (never deployed), :deploying/:starting (the reconciler's
  # lane — stale timeout and Deployment mirroring converge them).
  defp sweep_instance(_instance), do: {:ok, nil}

  # The row as it is NOW, not as the snapshot remembers it. Only a
  # still-stranded row flips; moved rows skip (the next pass re-decides
  # under whatever owns them now), and an unreadable row skips — never
  # park anchors on a failed read.
  defp still_stranded?(instance) do
    case Ash.get(Instance, instance.id, authorize?: false) do
      {:ok, %Instance{status: status}} when status in @stranded_statuses ->
        true

      # coveralls-ignore-start - race-window arm: reachable only when
      # the row's status moved between call/0's snapshot read and this
      # re-read microseconds-to-minutes later; not expressible in a
      # synchronous single-transaction test.
      {:ok, %Instance{status: moved}} ->
        Logger.info(
          "Instance #{instance.id}: status moved to #{moved} during the sweep pass; leaving it"
        )

        false

      # coveralls-ignore-stop

      # coveralls-ignore-start - race/DB-failure arm: covers both a row
      # destroyed mid-pass (Ash NotFound) and a read error that needs
      # the DB down; neither is expressible in a synchronous test.
      {:error, _error} ->
        false
        # coveralls-ignore-stop
    end
  end

  defp accruing?(instance), do: not is_nil(instance.storage_metering_since)

  # Only a definitive 404 strands: an unreadable cluster (kubeconfig
  # or API failure) is a skip, never a destroy.
  defp namespace_definitively_gone?(%{namespace: nil}), do: false

  defp namespace_definitively_gone?(instance) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        case Namespace.exists?(kubeconfig, instance.namespace) do
          {:ok, false} -> true
          _present_or_unreadable -> false
        end

      {:error, _error} ->
        false
    end
  end

  # Arm 3: namespaces that outlived their rows.
  defp sweep_cluster(cluster, live_ids) do
    case InstanceK8s.kubeconfig_for(%{cluster_id: cluster.id}) do
      {:ok, kubeconfig} ->
        sweep_cluster_namespaces(kubeconfig, live_ids)

      {:error, error} ->
        Logger.error("Orphan sweep failed for cluster #{cluster.id}: #{inspect(error)}")

        {:error, error}
    end
  end

  defp sweep_cluster_namespaces(kubeconfig, live_ids) do
    case Namespace.list(kubeconfig) do
      {:ok, items} ->
        names = for item <- items, name = orphan_name(item, live_ids), do: name

        with {:ok, confirmed} <- confirm_orphans(names) do
          delete_orphan_namespaces(kubeconfig, confirmed)
        end

      {:error, error} ->
        Logger.error("Orphan sweep failed to list namespaces: #{inspect(error)}")

        {:error, error}
    end
  end

  # Verify each candidate against the rows as they are NOW (the
  # snapshot is as old as the pass). An unreadable row — anything but
  # NotFound — is NOT absent: the candidate is protected, the cluster
  # unit fails, and the caller's Oban retry owns recovery (#159).
  defp confirm_orphans(names) do
    outcome =
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, confirmed} ->
        case row_appeared?(name) do
          # coveralls-ignore-start - the appeared arm rides the same
          # race window as row_appeared?'s (excluded there).
          {:ok, true} ->
            {:cont, {:ok, confirmed}}

          # coveralls-ignore-stop

          {:ok, false} ->
            {:cont, {:ok, [name | confirmed]}}

          # coveralls-ignore-start - reachable only from
          # row_appeared?'s DB-failure arm (excluded there).
          {:error, error} ->
            {:halt, {:error, error}}
            # coveralls-ignore-stop
        end
      end)

    # coveralls-ignore-start - the finishing case's error arm and its
    # `end` line ride the same DB-failure exclusion.
    case outcome do
      {:ok, confirmed} -> {:ok, Enum.reverse(confirmed)}
      {:error, _error} = error -> error
    end

    # coveralls-ignore-stop
  end

  # {:ok, boolean} — the row is verifiably live/absent; {:error, _} —
  # unreadable. The uuid shape is regex-guaranteed upstream, so a miss
  # is always the NotFound class; if Ash.get's miss shape ever changes,
  # the unmatched clause raises into the unit rescue — safe direction
  # (protected namespace, failed pass).
  defp row_appeared?(name) do
    id = String.trim_leading(name, "fluxvale-app-")

    case Ash.get(Instance, id, authorize?: false) do
      # coveralls-ignore-start - race-window arm: reachable only when a
      # row is created between call/0's snapshot read and this re-read
      # microseconds-to-minutes later; not expressible in a synchronous
      # single-transaction test.
      {:ok, %Instance{id: instance_id}} ->
        Logger.warning("Orphan sweep: namespace #{name} belongs to live instance #{instance_id}")

        {:ok, true}

      # coveralls-ignore-stop
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} ->
        {:ok, false}

      # coveralls-ignore-start - DB-failure arm: a non-NotFound read
      # error needs the DB down; ExUnit can't simulate it (the AGENTS
      # cluster-level stance).
      {:error, error} ->
        Logger.error("Orphan sweep: row re-read failed for #{name}: #{inspect(error)}")

        {:error, error}

        # coveralls-ignore-stop
    end
  end

  defp delete_orphan_namespaces(kubeconfig, names) do
    results = Enum.map(names, fn name -> {name, delete_orphan(kubeconfig, name)} end)

    errors = for {_name, {:error, error}} <- results, do: error

    if errors == [] do
      {:ok, {:orphans, for({name, :ok} <- results, do: name)}}
    else
      Logger.error("Orphan namespace deletion failed: #{inspect(errors)}")

      {:error, :orphan_delete_failed}
    end
  end

  # 404 is the goal already achieved (vanished between list and delete
  # — operator, or an overlapping pass), not a failure; same tolerance
  # as TeardownInstance's deletes.
  defp delete_orphan(kubeconfig, name) do
    case Namespace.delete(kubeconfig, name) do
      :ok -> :ok
      {:error, %Error{reason: :not_found}} -> :ok
      {:error, _error} = error -> error
    end
  end

  # An instance namespace by name shape, phase, and OUR env label, with
  # a live row to answer it — anything else (platform namespaces,
  # uuid-malformed names, Terminating GC, foreign-env or unlabeled
  # namespaces) is not ours to touch (#196: the env label is what stops
  # one platform env from deleting another's namespaces on the shared
  # box). The label comes off the list item itself — no extra read.
  defp orphan_name(item, live_ids) do
    name = get_in(item, ["metadata", "name"])
    phase = get_in(item, ["status", "phase"])

    if orphan_shaped?(item, name, phase) do
      id = String.trim_leading(name, "fluxvale-app-")

      if MapSet.member?(live_ids, id), do: nil, else: name
    else
      nil
    end
  end

  # Unlabeled (pre-#196 deploys, operator-placed) reads as foreign:
  # never deleted, only re-labeled by a re-deploy.
  defp orphan_shaped?(item, name, phase) do
    is_binary(name) and Regex.match?(@instance_namespace_regex, name) and phase == "Active" and
      get_in(item, ["metadata", "labels", @env_label]) == platform_env()
  end

  defp platform_env do
    Application.fetch_env!(:flux_vale, :platform_env)
  end

  defp teardown_job_live?(instance_id) do
    worker = teardown_worker_name()

    query =
      Oban.Job
      |> where([j], j.worker == ^worker and j.state in @live_job_states)
      |> where([j], fragment("args->'primary_key'->>'id' = ?", ^instance_id))

    Repo.exists?(query)
  end

  # The trigger's own worker module — rename-safe, no hardcoded string.
  # Oban.Worker.to_string/1 is Oban's stored form (a bare Atom.to_string
  # would carry the "Elixir." prefix and never match a job row).
  defp teardown_worker_name do
    trigger = AshOban.Info.oban_trigger(Instance, :teardown)

    Oban.Worker.to_string(trigger.worker)
  end

  defp summarize(results) do
    entries = for {:ok, entry} <- results, not is_nil(entry), do: entry

    %__MODULE__{
      requeued_teardown_ids: collect(entries, :requeued_teardown),
      lost_ids: collect(entries, :lost),
      deleted_orphan_namespaces: orphan_names(entries)
    }
  end

  defp collect(entries, kind) do
    for {^kind, id} <- entries, do: id
  end

  defp orphan_names(entries) do
    Enum.flat_map(entries, fn
      {:orphans, names} -> names
      _entry -> []
    end)
  end

  # One bad unit is logged and skipped, not allowed to eat the sweep —
  # the job still fails after the loop (call/0's failure count).
  defp safe_sweep_instance(instance) do
    sweep_instance(instance)
  rescue
    exception ->
      Logger.error("Instance sweep failed for #{instance.id}: #{Exception.message(exception)}")

      {:error, exception}
  end

  defp safe_sweep_cluster(cluster, live_ids) do
    sweep_cluster(cluster, live_ids)
  rescue
    exception ->
      Logger.error(
        "Orphan sweep crashed for cluster #{cluster.id}: #{Exception.message(exception)}"
      )

      {:error, exception}
  end
end
