defmodule FluxVale.Infrastructure.Operations.SleepInstance do
  @moduledoc """
  Sleeps a `:running` Instance (#203, ADR-0036): scales the Deployment
  to 0 (the Okteto pattern — PVC, Services and routes stay) and flips
  the edge routes to wake mode, so the next visitor lands on the wake
  endpoint instead of a connectionless Service.

  Billing needs no code here: leaving `:running` folds the running
  anchor (MaintainAnchors) and the storage anchor keeps accruing — a
  sleeping instance settles at storage-only, exactly a stopped one
  (ADR-0028 §2).

  Failure posture, in apply order:

  - scale fails → `:error` (`:stop_failed` copy fits: "we couldn't
    stop your app"); the instance keeps serving and the row stays
    `:error` — the sweep only ever reads `:running`, so recovery is
    the owner's retry (a rare, loudly-surfaced shape, not a loop).
  - edge flip fails after a successful scale → `:stopped`, NOT
    `:sleeping`: the routes still point at the app Service, so traffic
    would 503 with nobody able to wake it. Stopped is the pre-#203
    degraded-but-honest shape (owner Start works, ingress is already
    correct).
  """

  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @doc """
  Scales to zero, flips the edge, lands `:sleeping`. Returns `{:ok,
  instance}` either way — the `status` attribute carries the outcome.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: :running} = instance) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        scale_then_flip(kubeconfig, instance)

      {:error, error} ->
        sleep_failed(instance, error)
    end
  end

  # A concurrent writer moved the state on — nothing to sleep.
  def call(instance), do: {:ok, instance}

  defp scale_then_flip(kubeconfig, instance) do
    case Deployment.scale(kubeconfig, instance.namespace, "app", 0) do
      {:ok, _deployment} -> flip_edge(kubeconfig, instance)
      {:error, error} -> sleep_failed(instance, error)
    end
  end

  # The scale landed, so the workload is down whatever happens next —
  # the remaining question is only whether visitors can wake it.
  defp flip_edge(kubeconfig, instance) do
    case EdgeRoutes.apply_wake(kubeconfig, instance) do
      :ok ->
        InstanceK8s.update_status(instance, :sleeping, nil)

      {:error, error} ->
        # Routes still point at the app Service: traffic would 503 with
        # nobody able to wake it. Stopped is the honest shape — owner
        # Start works, the routes are already correct (the pre-#203
        # stopped behavior, billing included).
        InstanceK8s.update_status(
          instance,
          :stopped,
          "Slept without wake routing; owner can start it again (#{InstanceK8s.format_error(error)})"
        )
    end
  end

  defp sleep_failed(instance, error) do
    InstanceK8s.update_status(
      instance,
      :error,
      "Sleep failed: #{InstanceK8s.format_error(error)}",
      :stop_failed
    )
  end
end
