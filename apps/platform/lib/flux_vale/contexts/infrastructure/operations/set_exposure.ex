defmodule FluxVale.Infrastructure.Operations.SetExposure do
  @moduledoc """
  Applies an exposure change to the cluster (#265) — the instant
  kill-switch half of the primitive:

  - **→ private**: delete the public routes first, then tighten the
    namespace NetworkPolicy to same-namespace-only ingress. Routes
    first is fail-closed: with no route, no traffic reaches the
    namespace whatever the policy admits; a later step failing leaves
    the row claiming `public` (the action errors, nothing half-holds),
    and a public row's next route-apply restores exactly that.
  - **→ public**: mint the routes in the row's current mode — wake
    mode for a sleeping instance (so a visitor can wake it), serving
    otherwise — then re-admit the edge in the policy.

  In-cluster paths never notice either direction: panel operations,
  sweeps, backups, and health ride the API server and in-namespace
  workloads, never the edge exception the policy widens or narrows.

  The future access layer (#265's provider-agnostic seam) attaches
  alongside this op — it grants reachability to `:private` rows; it
  must not widen this policy's edge entry.
  """

  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @policy "default-deny-ingress"

  @doc """
  Applies `instance.exposure` to the cluster. `:ok` when the cluster
  holds the posture; `{:error, reason}` otherwise (the caller — the
  `set_exposure` action — fails the write on it, so the row never
  claims a posture the cluster hasn't reached).
  """
  @spec call(Instance.t()) :: :ok | {:error, term()}
  def call(instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      apply_exposure(kubeconfig, instance)
    end
  end

  defp apply_exposure(kubeconfig, %{exposure: :private} = instance) do
    with :ok <- EdgeRoutes.apply_private(kubeconfig, instance) do
      apply_policy(kubeconfig, instance, :private)
    end
  end

  defp apply_exposure(kubeconfig, %{exposure: :public, status: status} = instance) do
    mode = if(status == :sleeping, do: :wake, else: :serving)

    with :ok <- apply_routes(kubeconfig, instance, mode) do
      apply_policy(kubeconfig, instance, :public)
    end
  end

  defp apply_routes(kubeconfig, instance, :wake), do: EdgeRoutes.apply_wake(kubeconfig, instance)

  defp apply_routes(kubeconfig, instance, :serving),
    do: EdgeRoutes.apply_serving(kubeconfig, instance)

  defp apply_policy(kubeconfig, instance, exposure) do
    case NetworkPolicy.create(
           kubeconfig,
           instance.namespace,
           @policy,
           InstanceK8s.network_policy_spec(exposure)
         ) do
      {:ok, _policy} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
