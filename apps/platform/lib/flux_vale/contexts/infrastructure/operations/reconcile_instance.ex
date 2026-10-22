defmodule FluxVale.Infrastructure.Operations.ReconcileInstance do
  @moduledoc """
  Mirrors the real K8s Deployment state into the Instance's `status` —
  the AshOban `:reconcile_status` trigger's body, every minute (ADR-0005).
  Idempotent; the **only writer of `:running`**:

  - `:deploying` stuck past the stale timeout (deploy job died
    mid-flight) → `:error`; a fresh `:deploying` is the deploy job's
    state — not fought over
  - `:starting` + readyReplicas ≥ replicas → `:running`
  - `:starting`/`:running` + failed rollout conditions
    (`ReplicaFailure`, `ProgressDeadlineExceeded`) → `:error`
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
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Logger
  require OpenTelemetry.Tracer

  @deploy_stale_timeout_seconds Application.compile_env(
                                  :flux_vale,
                                  :deploy_stale_timeout_seconds,
                                  300
                                )

  @doc """
  Reconciles one Instance. Returns `{:ok, instance}` — reconcile outcomes
  are status writes, not job failures (v1 contract, kept).

  One `instance.reconcile` span per pass (ADR-0012 Am. 1), status
  `:error` on the flips — the deploy→running arc reads as one trace
  alongside `instance.deploy`.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: status} = instance) when status in [:deploying, :starting, :running] do
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

  defp reconcile(%{status: status} = instance) when status in [:starting, :running] do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        mirror_deployment_status(kubeconfig, instance)

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
        transition_for(instance, deployment_status)

      {:error, %Error{reason: reason}} when reason in [:not_found, :forbidden] ->
        vanished_deployment_outcome(kubeconfig, instance, reason)

      {:error, error} ->
        # Transient K8s API read failure — don't flip status on a failed
        # read. Logged, never silent: a detector that fails quietly is
        # indistinguishable from one that affirmed health (#196's
        # 90-minute blind spot).
        Logger.warning(
          "Instance #{instance.id}: reconcile read failed (#{error.message}); leaving #{instance.status}"
        )

        {:ok, instance}
    end
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

  defp transition_for(instance, %{replicas: desired, ready: ready, conditions: conditions}) do
    cond do
      failed_rollout?(conditions) ->
        message = rollout_failure_message(conditions)

        Logger.warning(
          "Instance #{instance.id}: failed rollout condition detected; marking :error (#{message})"
        )

        flip_to_error(instance, message, :rollout_failed)

      desired > 0 and ready >= desired ->
        if instance.status == :starting do
          InstanceK8s.update_status(instance, :running, nil)
        else
          {:ok, instance}
        end

      true ->
        # Still progressing, or externally scaled to zero — no autonomous
        # decision (v1 stance, kept).
        {:ok, instance}
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

  # A True ReplicaFailure or a ProgressDeadlineExceeded Progressing
  # condition both signal a failed rollout (crash-loop, image pull, ...).
  defp failure_condition?(%{"type" => "ReplicaFailure", "status" => "True"}), do: true

  defp failure_condition?(%{
         "type" => "Progressing",
         "status" => "False",
         "reason" => "ProgressDeadlineExceeded"
       }),
       do: true

  defp failure_condition?(_condition), do: false

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
