defmodule FluxVale.Infrastructure.Operations.InstanceK8s do
  @moduledoc """
  Shared seam for the Instance lifecycle operations: cluster kubeconfig
  resolution, system status writes, and K8s error formatting.

  Not a user-facing operation — the verb modules (Deploy/Reconcile/
  Teardown/Stop/StartInstance) own the lifecycle decisions; this owns the
  mechanics they need identically (the one sanctioned shared helper set —
  duplicating it five ways is the boundary error, not sharing it).
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance

  @doc """
  Resolves the Instance's cluster and its kubeconfig. Cluster read runs
  `authorize?: false` — placement is global config, not actor-scoped data
  (the Cluster policy posture, #72).

  Spec'd `map()`, not `Instance.t()`: an `Instance.t()` arg here makes
  dialyzer collapse the contract to the error branch at the lifecycle
  ops' call sites (the with/Ash.get inference chain) — map() keeps the
  contract honest for every caller shape.
  """
  @spec kubeconfig_for(map()) ::
          {:ok, Kubereq.Kubeconfig.t()} | {:error, term()}
  def kubeconfig_for(%{cluster_id: cluster_id}) do
    with {:ok, cluster} <- Ash.get(Cluster, cluster_id, authorize?: false) do
      K8s.kubeconfig(cluster.kubeconfig_ref)
    end
  end

  @doc """
  System status write through `:update_status`. `authorize?: false`: the
  trigger context has no actor and the AshOban bypass doesn't propagate
  to nested calls — the user-facing entry actions (deploy/stop/start/
  delete) carry the ownership policy check. The namespace never changes
  here: it is write-once, pinned by the deploy action.
  """
  @spec update_status(Instance.t(), atom(), String.t() | nil) ::
          {:ok, Instance.t()} | {:error, term()}
  def update_status(instance, status, status_message) do
    # Messages are capped at the resource's 500-char validation — K8s
    # condition strings routinely exceed it, and an over-long message
    # would fail the write itself (a worse outcome than a truncated one).
    params = %{status: status, status_message: truncate(status_message, 500)}

    instance
    |> Ash.Changeset.for_update(:update_status, params, authorize?: false)
    |> Ash.update()
  end

  @doc """
  Formats a K8s/client error into a status_message-worthy string.
  """
  @spec format_error(term()) :: String.t()
  def format_error(%{message: message}) when is_binary(message), do: message
  # coveralls-ignore-next-line - defensive: K8s errors are %Error{} or strings
  def format_error(other), do: inspect(other)

  defp truncate(nil, _limit), do: nil

  defp truncate(message, limit) when is_binary(message) do
    String.slice(message, 0, limit)
  end
end
