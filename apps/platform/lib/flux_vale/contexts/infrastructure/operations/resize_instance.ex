defmodule FluxVale.Infrastructure.Operations.ResizeInstance do
  @moduledoc """
  Re-applies an instance's footprint to the cluster after a resize
  (#493): the ResourceQuota (new compute + storage, platform margins
  included), the data PVC (only when storage actually moved), and the
  Deployment — all server-side apply, so a retry converges (re-apply =
  no-op where the cluster already matches).

  Replicas follow the LIVE claim — 0 while stopped (the ordinary
  stopped-first case: the pod template rolls with no pod churn and the
  workload runs at the new size on next start); a racing start's
  scale-to-one is preserved, so the template rolls at the new size and
  the start completes honestly.

  The PVC, the 0→N file-access world, and the deployment re-apply live in
  `ClusterFootprint` (shared with #250's online storage growth). Deploy's
  env recomputation is deliberately NOT re-run here (it is
  exposure-dependent and deploy-time-frozen — a recompute can strip the
  other way); what the pod already references is what the re-apply keeps.
  """

  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ClusterFootprint
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @doc """
  Re-applies quota, storage, and deployment. `previous_storage_gb` is
  the pre-resize row's storage (the action holds it — no re-read);
  nil = no allocation on record (drift) and reads as the mint arm.
  `:ok` when the cluster holds the new footprint; `{:error, reason}`
  otherwise — the resize action fails the write on it, so the row never
  claims an allocation the cluster hasn't reached (the set_exposure
  contract).
  """
  @spec call(Instance.t(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def call(%Instance{} = updated, previous_storage_gb) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(updated),
         {:ok, spec} <- InstanceK8s.quota_spec(updated),
         {:ok, _quota} <- ResourceQuota.create(kubeconfig, updated.namespace, "app-quota", spec),
         :ok <- ClusterFootprint.apply_storage(kubeconfig, updated, previous_storage_gb),
         :ok <-
           ClusterFootprint.maybe_mint_file_access_world(kubeconfig, updated, previous_storage_gb) do
      ClusterFootprint.apply_deployment(kubeconfig, updated)
    end
  end
end
