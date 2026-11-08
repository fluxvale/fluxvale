defmodule FluxVale.Infrastructure.Operations.GrowStorageVolume do
  @moduledoc """
  The online storage-only apply (#250): the ResourceQuota, the `app-data`
  PVC at `max(row, live)`, and — only on the 0→N file-access crossing —
  the sidecar's world plus a Deployment re-apply so the WebDAV container
  exists. A normal N→M grow touches no Deployment: the pod does not roll,
  so the workload may need a restart to see the new space (stated in the
  approval copy).

  The capability gate is the guard's; this operation only applies what the
  row already claims. `:ok` when the cluster holds the new volume;
  `{:error, reason}` otherwise — the action fails the write on it, so the
  row never claims a volume the cluster hasn't reached (the set_exposure
  contract).
  """

  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ClusterFootprint
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @doc """
  Applies the growth. `previous_storage_gb` is the pre-action row's
  storage (the action holds it — no re-read).
  """
  @spec call(Instance.t(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def call(%Instance{} = updated, previous_storage_gb) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(updated),
         {:ok, spec} <- InstanceK8s.quota_spec(updated),
         {:ok, _quota} <- ResourceQuota.create(kubeconfig, updated.namespace, "app-quota", spec),
         :ok <- ClusterFootprint.apply_storage(kubeconfig, updated, previous_storage_gb),
         :ok <-
           ClusterFootprint.maybe_mint_file_access_world(kubeconfig, updated, previous_storage_gb) do
      maybe_apply_deployment(kubeconfig, updated, previous_storage_gb)
    end
  end

  # The one honest pod roll on this path: the 0→N crossing gains the
  # WebDAV sidecar, so the Deployment is re-applied at the row's footprint.
  # Every other grow leaves the Deployment alone.
  defp maybe_apply_deployment(kubeconfig, updated, previous_storage_gb) do
    if ClusterFootprint.mints_file_access_world?(updated, previous_storage_gb) do
      ClusterFootprint.apply_deployment(kubeconfig, updated)
    else
      :ok
    end
  end
end
