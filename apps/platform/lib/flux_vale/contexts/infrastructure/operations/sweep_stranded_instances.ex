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
  - **Namespace gone, row alive** — accruing rows (`:running`/
    `:stopped`/`:error` with `storage_metering_since` set) whose
    namespace 404s. `:stopped` is the worst leak: outside the
    reconciler entirely, it accrues storage forever on a dead
    namespace. Driven through the standard funnel (`:deleting` +
    teardown) — rows die only through teardown. Never-ran `:error`
    rows accrue nothing and stay retryable. Only a definitive 404
    counts: kubeconfig or API failures skip the row, never strand it.
  - **Orphaned namespaces** — `fluxvale-app-<uuid>`-shaped, phase
    `Active`, no matching row: deleted, with the row re-checked
    immediately before the destructive call (the live-id snapshot is
    stale by however long the pass's cluster reads took — a deploy
    landing mid-pass must not lose its fresh namespace, and an
    unreadable re-read protects the candidate and fails the pass).
    `Terminating` is skipped — that's normal teardown GC (the row dies
    before the namespace finishes disappearing). A 404 on the delete
    is the goal already achieved, not a failure.

  Complements, never fights: `:starting`/`:running` stay the
  reconciler's (it flips both to `:error` within a minute of the
  namespace dying; `:deploying` converges on its own stale-deploy
  timeout) and the next sweep catches the `:error`; the #124 ladder
  keeps the only time-based destroy authority — this sweep is
  condition-based only, so races with the ladder converge (a live
  teardown job is a skip; a lost one gets re-driven to the same
  terminal state the ladder already decided).
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
  @stranded_statuses [:running, :stopped, :error]

  @teardown_message "Namespace gone from cluster; sweeper tearing down"

  @enforce_keys [:requeued_teardown_ids, :torn_down_ids, :deleted_orphan_namespaces]
  defstruct [:requeued_teardown_ids, :torn_down_ids, :deleted_orphan_namespaces]

  @type t :: %__MODULE__{
          requeued_teardown_ids: [Ash.UUID.t()],
          torn_down_ids: [Ash.UUID.t()],
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

  # Arm 2: an accruing row whose namespace is verifiably gone goes
  # through the standard teardown funnel.
  defp sweep_instance(%{status: status} = instance) when status in @stranded_statuses do
    if accruing?(instance) and namespace_definitively_gone?(instance) do
      {:ok, deleting} = InstanceK8s.update_status(instance, :deleting, @teardown_message)

      AshOban.run_trigger(deleting, :teardown)

      {:ok, {:torn_down, instance.id}}
    else
      {:ok, nil}
    end
  end

  # :pending (never deployed), :deploying/:starting (the reconciler's
  # lane — stale timeout and Deployment mirroring converge them).
  defp sweep_instance(_instance), do: {:ok, nil}

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

  # An instance namespace by name shape and phase, with a live row to
  # answer it — anything else (platform namespaces, uuid-malformed
  # names, Terminating GC) is not ours to touch.
  defp orphan_name(item, live_ids) do
    name = get_in(item, ["metadata", "name"])
    phase = get_in(item, ["status", "phase"])

    if orphan_shaped?(name, phase) do
      id = String.trim_leading(name, "fluxvale-app-")

      if MapSet.member?(live_ids, id), do: nil, else: name
    else
      nil
    end
  end

  defp orphan_shaped?(name, phase) do
    is_binary(name) and Regex.match?(@instance_namespace_regex, name) and phase == "Active"
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
      torn_down_ids: collect(entries, :torn_down),
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
