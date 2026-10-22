defmodule FluxVale.Infrastructure.Operations.StartInstance do
  @moduledoc """
  Starts a `:stopped` Instance — or wakes a `:sleeping` one (#203,
  ADR-0036) — by scaling its Deployment back to 1.

  Lands `:starting`, never `:running` — the reconciler confirms real
  readiness (ADR-0005: it is the only writer of `:running`). On K8s
  failure the Instance flips to `:error` with the reason.

  Wake is deliberately the same operation as start: the state machine
  differs (`sleeping → starting` vs `stopped → starting`), the cluster
  work doesn't. The edge routes stay pointed at the wake endpoint until
  the instance is `:running` — `FluxVale.Infrastructure.Operations.
  RestoreServingEdge` flips them on the first post-wake request, so the
  waking visitor never meets a connectionless service.
  """

  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @doc """
  Scales to one and lands `:starting`. Returns `{:ok, instance}` either
  way — the `status` attribute carries the outcome.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: status} = instance) when status in [:stopped, :sleeping] do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, _deployment} <- Deployment.scale(kubeconfig, instance.namespace, "app", 1) do
      InstanceK8s.update_status(instance, :starting, "Starting; awaiting readiness")
    else
      {:error, error} ->
        InstanceK8s.update_status(
          instance,
          :error,
          "Start failed: #{InstanceK8s.format_error(error)}",
          :start_failed
        )
    end
  end

  # A concurrent writer moved the state on — nothing to start.
  def call(instance), do: {:ok, instance}
end
