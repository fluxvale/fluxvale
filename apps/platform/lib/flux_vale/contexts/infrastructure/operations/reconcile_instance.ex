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
  - `:starting`/`:running` whose Deployment vanished → `:error`
  - transient K8s read failures / config errors → no-op (status never
    churns on a failed read; `running` never demotes on readiness blips)

  Staleness reads `deployed_at`, not `updated_at` — every reconcile bumps
  `updated_at` even on a no-op (v1 finding, kept).
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Logger

  @deploy_stale_timeout_seconds Application.compile_env(
                                  :flux_vale,
                                  :deploy_stale_timeout_seconds,
                                  300
                                )

  @doc """
  Reconciles one Instance. Returns `{:ok, instance}` — reconcile outcomes
  are status writes, not job failures (v1 contract, kept).
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: :deploying} = instance) do
    if stale_deploy?(instance) do
      Logger.warning(
        "Instance #{instance.id} deploy stuck >#{@deploy_stale_timeout_seconds}s; timing out to :error"
      )

      InstanceK8s.update_status(
        instance,
        :error,
        instance.namespace,
        "Deploy job stuck; timed out"
      )
    else
      {:ok, instance}
    end
  end

  def call(%{status: status} = instance) when status in [:starting, :running] do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        mirror_deployment_status(kubeconfig, instance)

      # Cluster/kubeconfig resolution failure — don't flip on config errors.
      {:error, _error} ->
        {:ok, instance}
    end
  end

  def call(instance), do: {:ok, instance}

  defp mirror_deployment_status(kubeconfig, instance) do
    case Deployment.status(kubeconfig, instance.namespace, "app") do
      {:ok, deployment_status} ->
        transition_for(instance, deployment_status)

      {:error, %Error{reason: :not_found}} ->
        Logger.warning("Instance #{instance.id}: Deployment not found in cluster; marking :error")

        InstanceK8s.update_status(
          instance,
          :error,
          instance.namespace,
          "Deployment not found in cluster"
        )

      {:error, _error} ->
        # Transient K8s API read failure — don't flip status on a failed read.
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

        InstanceK8s.update_status(instance, :error, instance.namespace, message)

      desired > 0 and ready >= desired ->
        if instance.status == :starting do
          InstanceK8s.update_status(instance, :running, nil, nil)
        else
          {:ok, instance}
        end

      true ->
        # Still progressing, or externally scaled to zero — no autonomous
        # decision (v1 stance, kept).
        {:ok, instance}
    end
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
