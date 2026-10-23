defmodule FluxVale.Infrastructure.Operations.RestoreServingEdge do
  @moduledoc """
  Flips a woken instance's edge routes back to serving mode (#203,
  ADR-0036) — the last step of every wake, driven by the first request
  that finds the instance `:running` (the waking page's reload).

  Why request-driven, not promotion-driven: the reconciler stays
  read-only (ADR-0005's split), and this placement is self-healing —
  a failed restore, a wake triggered by the owner's Wake button, a
  no-poller wake (an API client's retry) all converge on the next
  request, whatever path missed it. `:ok | {:error, reason}`; the
  caller serves the retry hint either way.
  """

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @doc """
  Re-applies the serving-mode routes. Idempotent (SSA) — safe on every
  post-wake request until the flip lands.
  """
  @spec call(Instance.t()) :: :ok | {:error, term()}
  def call(instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      EdgeRoutes.apply_serving(kubeconfig, instance)
    end
  end
end
