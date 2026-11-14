defmodule FluxVale.Infrastructure.Operations.ReconcileInstance do
  @moduledoc """
  Mirrors the real K8s Deployment state into the Instance's `status` —
  the AshOban `:reconcile_status` trigger's body, every minute (ADR-0005).
  Idempotent; the **only writer of `:running`**:

  - `:deploying` stuck past the stale timeout (deploy job died
    mid-flight) → `:error`; a fresh `:deploying` is the deploy job's
    state — not fought over
  - `:starting`/`:no_capacity`/`:error` whose CURRENT revision is
    replicated and ready → `:running` (the `:running` case is a no-op);
    readiness outranks leftover failed-rollout conditions
  - `:starting`/`:running`/`:error`/`:no_capacity` + an unschedulable
    pod (`PodScheduled=False` / `Unschedulable`) → `:no_capacity`, with
    the pod's condition reason in `status_message` — capacity is not a
    crash
  - `:starting`/`:running` + failed rollout conditions
    (`ReplicaFailure`, `ProgressDeadlineExceeded`) on a not-yet-ready
    current revision → `:error`; a fresh `ReplicaFailure` is retried
    (the ReplicaSet controller recreates a rejected pod, and a
    terminating pod holds the quota until it goes) and only a failure
    older than the deploy-stale bound is terminal. An unschedulable pod
    is reported as `:no_capacity` FIRST: capacity/placement is not a
    failed rollout, so the deadline and the 300s bound do not turn it
    into `:error` — the row waits for the scheduler (or the owner's
    stop) instead
  - `:error` rows whose failure is unintended (stuck/missing/rollout/
    start) and whose current revision is now ready → `:running`; the
    intent-bearing failures (`:stop_failed`, `:restore_failed`,
    `:teardown_failed`) keep their error
  - `:starting`/`:running` whose Deployment vanished (404) or became
    unreadable as **403** (the per-namespace RoleBinding dies with the
    namespace, so a deleted namespace answers Deployment reads with
    Forbidden, not NotFound — #196's reconciler blind spot) → `:lost`
    if the namespace went with it (external deletion); `:error` when
    only the Deployment is gone (404 in a live namespace); a logged
    no-op when a live namespace's read was forbidden (RBAC anomaly,
    not a loss)
  - transient K8s read failures / config errors → no-op, **logged**
    (status never churns on a failed read; `running` never demotes on
    readiness blips — but a detector that fails quietly is
    indistinguishable from one that affirmed health)

  Staleness reads `deployed_at`, not `updated_at` — every reconcile bumps
  `updated_at` even on a no-op (v1 finding, kept).
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.Pod
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Logger
  require OpenTelemetry.Tracer

  @deploy_stale_timeout_seconds Application.compile_env(
                                  :flux_vale,
                                  :deploy_stale_timeout_seconds,
                                  300
                                )

  # The app Deployment's pod labels; the instance namespace holds only
  # the app's pods (the gateway lives in its own namespace).
  @app_labels %{"app.kubernetes.io/name" => "app"}

  # A stuck `:error` row is not a terminal verdict: if the workload is
  # healthy now, the row was the stale half of an old failure. Only
  # unintended failures are recoverable — a failed stop/restore/teardown
  # carries the owner's (or the teardown's) intent and must stay error.
  # `nil` joins here (legacy rows); the trigger adds it explicitly
  # because SQL `IN` does not match NULL.
  @recoverable_error_reasons [
    nil | FluxVale.Infrastructure.Types.InstanceFailureReason.recoverable()
  ]

  @doc """
  Reconciles one Instance. Returns `{:ok, instance}` — reconcile outcomes
  are status writes, not job failures (v1 contract, kept).

  One `instance.reconcile` span per pass (ADR-0012 Am. 1), status
  `:error` on the flips — the deploy→running arc reads as one trace
  alongside `instance.deploy`.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: status} = instance)
      when status in [:deploying, :starting, :running, :no_capacity, :error] do
    OpenTelemetry.Tracer.with_span "instance.reconcile", reconcile_span_attrs(instance, status) do
      reconcile(instance)
    end
  end

  def call(instance), do: {:ok, instance}

  defp reconcile_span_attrs(instance, status) do
    # OTLP attribute keys are strings
    %{attributes: %{"instance.id" => instance.id, "instance.status" => Atom.to_string(status)}}
  end

  defp reconcile(%{status: :deploying} = instance) do
    if stale_deploy?(instance) do
      Logger.warning(
        "Instance #{instance.id} deploy stuck >#{@deploy_stale_timeout_seconds}s; timing out to :error"
      )

      flip_to_error(instance, "Deploy job stuck; timed out", :stuck)
    else
      {:ok, instance}
    end
  end

  # A never-deployed row has no Deployment to read; the row's own
  # failure stands.
  defp reconcile(%{status: :error, failure_reason: reason, namespace: nil} = instance)
       when reason in @recoverable_error_reasons,
       do: {:ok, instance}

  # The stuck-error recovery: the row outlived its failure, the workload
  # is healthy. Only unintended failures recover — see the module attr.
  defp reconcile(%{status: :error, failure_reason: reason} = instance)
       when reason in @recoverable_error_reasons do
    with_kubeconfig(instance, &recover_errored/2)
  end

  # An intent-bearing error (stop/restore/teardown) is not the
  # reconciler's to clear.
  defp reconcile(%{status: :error} = instance), do: {:ok, instance}

  defp reconcile(%{status: :no_capacity} = instance) do
    with_kubeconfig(instance, &recover_no_capacity/2)
  end

  defp reconcile(%{status: status} = instance) when status in [:starting, :running] do
    with_kubeconfig(instance, &mirror_deployment_status/2)
  end

  defp with_kubeconfig(instance, fun) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        fun.(kubeconfig, instance)

      # Cluster/kubeconfig resolution failure — don't flip on config
      # errors, but never silently (#196's visibility rule).
      {:error, error} ->
        Logger.warning(
          "Instance #{instance.id}: kubeconfig resolution failed (#{inspect(error)}); leaving #{instance.status}"
        )

        {:ok, instance}
    end
  end

  defp mirror_deployment_status(kubeconfig, instance) do
    case Deployment.status(kubeconfig, instance.namespace, "app") do
      {:ok, deployment_status} ->
        transition_for(kubeconfig, instance, deployment_status)

      {:error, %Error{reason: reason}} when reason in [:not_found, :forbidden] ->
        vanished_deployment_outcome(kubeconfig, instance, reason)

      {:error, error} ->
        log_read_failure(instance, error)
    end
  end

  # A never-applied Deployment on an errored row is a failed deploy, not
  # a loss; the sweep owns namespace loss. A *deployed* no_capacity row
  # whose Deployment vanished is the #196 shape and goes through the
  # same lost/missing decision as starting/running.
  defp recover_errored(kubeconfig, instance) do
    case Deployment.status(kubeconfig, instance.namespace, "app") do
      {:ok, %{replicas: desired} = status} when desired > 0 ->
        recover_if_ready(kubeconfig, instance, status)

      {:ok, _scaled_to_zero} ->
        {:ok, instance}

      {:error, %Error{reason: reason}} when reason in [:not_found, :forbidden] ->
        {:ok, instance}

      {:error, error} ->
        log_read_failure(instance, error)
    end
  end

  defp recover_no_capacity(kubeconfig, instance) do
    case Deployment.status(kubeconfig, instance.namespace, "app") do
      {:ok, %{replicas: desired} = status} when desired > 0 ->
        waiting_outcome(kubeconfig, instance, status)

      {:ok, _scaled_to_zero} ->
        {:ok, instance}

      {:error, %Error{reason: reason}} when reason in [:not_found, :forbidden] ->
        vanished_deployment_outcome(kubeconfig, instance, reason)

      {:error, error} ->
        log_read_failure(instance, error)
    end
  end

  defp waiting_outcome(kubeconfig, instance, status) do
    if current_revision_ready?(status) do
      promote_running(instance)
    else
      case scheduling_state(kubeconfig, instance) do
        {:unschedulable, reason} -> mark_no_capacity(instance, reason)
        :scheduled_or_absent -> back_to_starting(instance)
        {:error, _error} -> {:ok, instance}
      end
    end
  end

  defp recover_if_ready(kubeconfig, instance, status) do
    if current_revision_ready?(status) do
      promote_running(instance)
    else
      case scheduling_state(kubeconfig, instance) do
        {:unschedulable, reason} -> mark_no_capacity(instance, reason)
        _scheduled_or_unreadable -> {:ok, instance}
      end
    end
  end

  defp log_read_failure(instance, error) do
    # Transient K8s API read failure — don't flip status on a failed
    # read. Logged, never silent: a detector that fails quietly is
    # indistinguishable from one that affirmed health (#196's
    # 90-minute blind spot).
    Logger.warning(
      "Instance #{instance.id}: reconcile read failed (#{error.message}); leaving #{instance.status}"
    )

    {:ok, instance}
  end

  # A vanished or forbidden Deployment read means one of three things
  # (#196):
  #
  # - the namespace went with it — the external-deletion signature,
  #   `:lost` (metering parks, the owner decides). This is why
  #   `:forbidden` joins `:not_found` here: the platform SA's deployment
  #   reads ride the per-namespace RoleBinding
  #   (fluxvale-platform-workload), which dies WITH the namespace — so a
  #   deleted namespace answers Deployment GETs with **403, not 404**
  #   (the cluster-scoped role has no deployments verb). The pre-#196
  #   code matched `:not_found` only and silently no-op'd on the 403
  #   every minute — the incident's reconciler blind spot.
  # - the namespace lives and only the Deployment is gone — the
  #   pre-existing :error/:missing shape.
  # - the namespace lives and the read was forbidden — an RBAC anomaly,
  #   not a loss: warn and leave the row alone.
  #
  # The namespace double-check is authoritative either way: the
  # cluster-scoped role carries namespaces get, so `exists?` sees
  # through a dead namespace where the Deployment read cannot.
  defp vanished_deployment_outcome(kubeconfig, instance, deployment_reason) do
    case Namespace.exists?(kubeconfig, instance.namespace) do
      {:ok, false} ->
        Logger.warning(
          "Instance #{instance.id}: namespace not found in cluster; marking :lost (#196)"
        )

        OpenTelemetry.Tracer.set_status(:error, "namespace not found in cluster")

        InstanceK8s.update_status(
          instance,
          :lost,
          "Namespace gone from cluster; marked lost"
        )

      _namespace_present_or_unreadable when deployment_reason == :not_found ->
        Logger.warning("Instance #{instance.id}: Deployment not found in cluster; marking :error")

        flip_to_error(instance, "Deployment not found in cluster", :missing)

      _namespace_present_or_unreadable ->
        Logger.warning(
          "Instance #{instance.id}: Deployment read forbidden with the namespace present or unreadable (#{instance.namespace}) — RBAC anomaly or partial API failure, not a loss; leaving #{instance.status}"
        )

        {:ok, instance}
    end
  end

  defp stale_deploy?(%{deployed_at: nil}), do: false

  defp stale_deploy?(%{deployed_at: deployed_at}) do
    DateTime.diff(DateTime.utc_now(), deployed_at, :second) > @deploy_stale_timeout_seconds
  end

  # An externally scaled-to-zero Deployment has nothing to judge (the
  # platform did not scale it — v1 stance, kept).
  defp transition_for(_kubeconfig, instance, %{replicas: 0}), do: {:ok, instance}

  defp transition_for(kubeconfig, instance, %{conditions: conditions} = status) do
    cond do
      current_revision_ready?(status) ->
        promote_running(instance)

      other = unschedulable_pod(kubeconfig, instance) ->
        mark_no_capacity(instance, other)

      failed_rollout?(conditions) ->
        fail_rollout(instance, conditions)

      fresh_replica_failure?(conditions) ->
        log_held_rollout(instance, conditions)
        {:ok, instance}

      true ->
        # Still progressing, or externally scaled to zero — no autonomous
        # decision (v1 stance, kept).
        {:ok, instance}
    end
  end

  # The CURRENT revision is replicated and ready — the spec that is
  # serving now. Conditions left over from an earlier failed revision do
  # not outrank it; the updated-replicas check keeps a stalled rollout
  # honest, because ready old pods alone are not a rolled-out spec
  # (#776). Scaled-to-zero is handled by the caller's desired > 0 guard.
  defp current_revision_ready?(%{replicas: desired, ready: ready} = status) when desired > 0 do
    ready >= desired and Map.get(status, :updated, 0) >= desired
  end

  # Defensive: every caller passes desired > 0 (transition_for's zero
  # clause and the recovery guards).
  # coveralls-ignore-next-line
  defp current_revision_ready?(_status), do: false

  defp fail_rollout(instance, conditions) do
    message = rollout_failure_message(conditions)

    Logger.warning(
      "Instance #{instance.id}: failed rollout condition detected; marking :error (#{message})"
    )

    flip_to_error(instance, message, :rollout_failed)
  end

  defp promote_running(%{status: :running} = instance), do: {:ok, instance}

  defp promote_running(instance) do
    Logger.info("Instance #{instance.id}: workload is ready; promoting to :running")

    InstanceK8s.update_status(instance, :running, nil)
  end

  defp back_to_starting(%{status: :no_capacity} = instance) do
    Logger.info("Instance #{instance.id}: pod is schedulable again; returning to :starting")

    InstanceK8s.update_status(instance, :starting, "Starting; awaiting readiness")
  end

  defp mark_no_capacity(%{status: :no_capacity} = instance, _reason), do: {:ok, instance}

  defp mark_no_capacity(instance, reason) do
    Logger.warning("Instance #{instance.id}: pod unschedulable (#{reason}); marking :no_capacity")

    InstanceK8s.update_status(instance, :no_capacity, "Waiting for capacity — #{reason}")
  end

  # The Deployment is not ready; look at the newest non-terminating app
  # pod. A scheduler rejection is capacity, not a crash — and a read
  # failure must not be mistaken for either.
  defp unschedulable_pod(kubeconfig, instance) do
    case scheduling_state(kubeconfig, instance) do
      {:unschedulable, reason} -> reason
      _scheduled_absent_or_unreadable -> nil
    end
  end

  defp scheduling_state(kubeconfig, instance) do
    case Pod.list_by_labels(kubeconfig, instance.namespace, @app_labels) do
      {:ok, pods} ->
        pod = newest_pod(pods)
        pod_scheduling_state(pod)

      {:error, error} ->
        Logger.warning(
          "Instance #{instance.id}: pod read failed (#{error.message}); leaving #{instance.status}"
        )

        {:error, error}
    end
  end

  defp newest_pod(pods) do
    pods
    |> Enum.reject(&Pod.terminating?/1)
    |> Enum.sort_by(&Pod.started_at/1, {:desc, DateTime})
    |> List.first()
  end

  defp pod_scheduling_state(nil), do: :scheduled_or_absent

  defp pod_scheduling_state(pod) do
    case Pod.unschedulable_reason(pod) do
      nil -> :scheduled_or_absent
      reason -> {:unschedulable, reason}
    end
  end

  # Every :error flip marks the reconcile span failed — Tempo's
  # errored-spans view is the triage entry.
  defp flip_to_error(instance, message, failure_reason) do
    OpenTelemetry.Tracer.set_status(:error, message)

    InstanceK8s.update_status(instance, :error, message, failure_reason)
  end

  defp failed_rollout?(conditions) do
    Enum.any?(conditions, &failure_condition?/1)
  end

  # ReplicaFailure alone is not terminal: the ReplicaSet controller
  # recreates a pod admission rejected, and a terminating pod holds the
  # quota until it goes (the maxSurge:0 handoff). It becomes terminal
  # only after the deploy-stale bound; ProgressDeadlineExceeded is
  # Kubernetes' own terminal signal.
  defp failure_condition?(%{"type" => "ReplicaFailure", "status" => "True"} = condition),
    do: stale_condition?(condition)

  defp failure_condition?(%{
         "type" => "Progressing",
         "status" => "False",
         "reason" => "ProgressDeadlineExceeded"
       }),
       do: true

  defp failure_condition?(_condition), do: false

  defp fresh_replica_failure?(conditions) do
    Enum.any?(conditions, fn
      %{"type" => "ReplicaFailure", "status" => "True"} = condition ->
        not stale_condition?(condition)

      _condition ->
        false
    end)
  end

  defp stale_condition?(%{"lastTransitionTime" => timestamp}) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _offset} ->
        DateTime.diff(DateTime.utc_now(), at, :second) > @deploy_stale_timeout_seconds

      # Defensive: K8s always emits an RFC3339 stamp. An unreadable one
      # cannot prove the failure is fresh, so it stays terminal.
      {:error, _reason} ->
        true
    end
  end

  defp stale_condition?(_condition), do: true

  defp log_held_rollout(instance, conditions) do
    Logger.warning(
      "Instance #{instance.id}: ReplicaFailure while the rollout is progressing; " <>
        "holding #{instance.status} (#{condition_message(conditions, "ReplicaFailure") || "unknown"})"
    )
  end

  defp rollout_failure_message(conditions) do
    cond do
      message = condition_message(conditions, "ReplicaFailure") ->
        "Deployment failed: #{message}"

      message = condition_message(conditions, "Progressing") ->
        "Deployment failed: #{message}"

      true ->
        "Deployment failed: rollout stalled"
    end
  end

  defp condition_message(conditions, type) do
    case Enum.find(conditions, &(&1["type"] == type)) do
      %{"reason" => reason, "message" => message}
      when is_binary(reason) and is_binary(message) ->
        "#{reason}: #{message}"

      %{"reason" => reason} when is_binary(reason) ->
        reason

      _no_match ->
        nil
    end
  end
end
