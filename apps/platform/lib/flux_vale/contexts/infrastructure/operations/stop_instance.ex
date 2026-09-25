defmodule FluxVale.Infrastructure.Operations.StopInstance do
  @moduledoc """
  Stops a `:running` Instance by scaling its Deployment to 0 replicas —
  scale-to-zero is the product's pause (ADR-0005: stopped keeps the PVC,
  storage keeps accruing on the anchor, compute doesn't).

  On K8s failure the Instance flips to `:error` with the reason (v1
  contract: the caller sees the row, status carries the outcome).
  """

  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @doc """
  Scales to zero and lands `:stopped`. Returns `{:ok, instance}` either
  way — the `status` attribute carries the outcome.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: :running} = instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, _deployment} <- Deployment.scale(kubeconfig, instance.namespace, "app", 0) do
      InstanceK8s.update_status(instance, :stopped, nil, nil)
    else
      {:error, error} ->
        InstanceK8s.update_status(
          instance,
          :error,
          instance.namespace,
          "Stop failed: #{InstanceK8s.format_error(error)}"
        )
    end
  end

  # A concurrent writer moved the state on — nothing to stop.
  def call(instance), do: {:ok, instance}
end
