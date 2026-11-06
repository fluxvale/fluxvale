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

  Storage arms — the delta compares the PRE-resize row value the action
  passes: unchanged → skip the claim entirely; 0→N or a grow → re-apply
  the claim (capability already gated by the resize guard). The claim
  only ever widens: the applied size is `max(row, live)`, because a
  partial failure above (row rolled back, claim already landed) leaves
  the live claim wider than the row — a divergence that heals on the
  next resize to a target ≥ the live claim, instead of wedging every
  retry below it. The 0→N crossing on a file-access app additionally
  mints the sidecar's world — the credential Secret (get-or-create: a
  retrying resize never rotates the owner's rclone credential), the DAV
  Service, and the edge arms — exactly what a deploy at N GB would have
  minted (a deploy at gb=0 minted none of them).

  The env_from_secret decision reads the cluster's app-env Secret — one
  truth that can neither strip a live envFrom nor dangle a missing one.
  Deploy's env recomputation is deliberately NOT re-run here (it is
  exposure-dependent and deploy-time-frozen — a recompute can strip the
  other way); what the pod already references is what the re-apply
  keeps, and a missing Secret means no envFrom at all.

  The deployment spec carries no env recompute from the row: the Secret
  lookup above decides. The next deploy re-decides the Secret's CONTENT
  (ADR-0038 §4's env-snapshot stance).
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @env_secret "app-env"
  @claim "app-data"

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
         :ok <- apply_storage(kubeconfig, updated, previous_storage_gb),
         :ok <- maybe_mint_file_access_world(kubeconfig, updated, previous_storage_gb),
         {:ok, env} <- applied_env(kubeconfig, updated),
         {:ok, deployment} <- deployment_spec(kubeconfig, updated, env),
         {:ok, _deployment} <-
           Deployment.create(kubeconfig, updated.namespace, "app", deployment) do
      :ok
    end
  end

  # Replicas follow the live claim (see the moduledoc): the racing
  # start's scale-to-one is honest, the stopped-first 0 is the floor.
  defp deployment_spec(kubeconfig, updated, env) do
    with {:ok, replicas} <- live_replicas(kubeconfig, updated) do
      spec = InstanceK8s.deployment_spec(updated, env)

      {:ok, Map.put(spec, :replicas, replicas)}
    end
  end

  defp live_replicas(kubeconfig, updated) do
    case Deployment.get(kubeconfig, updated.namespace, "app") do
      {:ok, manifest} ->
        {:ok, live_or_zero(manifest)}

      {:error, %Error{reason: :not_found}} ->
        # Never deployed (or the claim was lost): the stopped-first 0.
        {:ok, 0}

      {:error, _reason} = error ->
        {:error, error}
    end
  end

  # The API defaults spec.replicas at admission — a missing field is a
  # defensive 0, not a guess about a live workload.
  defp live_or_zero(manifest) do
    case get_in(manifest, ["spec", "replicas"]) do
      replicas when is_integer(replicas) -> replicas
      _missing -> 0
    end
  end

  defp apply_storage(kubeconfig, updated, previous_storage_gb) do
    if previous_storage_gb == updated.storage_gb do
      # Unchanged — the claim is already the right size; no call.
      :ok
    else
      # 0→N mints; a grow re-applies wider (a shrink cannot reach
      # here — the guard refuses it).
      apply_claim(kubeconfig, updated)
    end
  end

  # The claim only ever widens (see the moduledoc): the applied size is
  # max(row, live) — the partial-failure divergence heals instead of
  # wedging every retry below the live claim.
  defp apply_claim(kubeconfig, updated) do
    with {:ok, live_gb} <- live_claim_gb(kubeconfig, updated),
         {:ok, _claim} <-
           PersistentVolumeClaim.upsert(kubeconfig, updated.namespace, @claim, %{
             size: "#{max(updated.storage_gb, live_gb)}Gi"
           }) do
      :ok
    end
  end

  defp live_claim_gb(kubeconfig, updated) do
    case PersistentVolumeClaim.get(kubeconfig, updated.namespace, @claim) do
      {:ok, manifest} ->
        parse_claim_gb(get_in(manifest, ["spec", "resources", "requests", "storage"]))

      {:error, %Error{reason: :not_found}} ->
        # Mint: no claim exists — the row's size is the floor.
        {:ok, 0}

      {:error, _reason} = error ->
        {:error, error}
    end
  end

  # "20Gi" → 20. A claim whose size we cannot parse is an
  # outage-class signal — fail the resize rather than re-apply a size
  # that could shrink a live claim.
  defp parse_claim_gb(size) when is_binary(size) do
    trimmed = String.trim_trailing(size, "Gi")

    case Integer.parse(trimmed) do
      {gb, ""} -> {:ok, gb}
      _garbage -> {:error, "cannot parse the live claim's size: #{inspect(size)}"}
    end
  end

  # coveralls-ignore-start - defensive: a claim without a size string
  # is not a shape the API server produces (requests.storage is
  # required on a bound claim); the arm keeps the function total.
  defp parse_claim_gb(_missing), do: {:error, "the live claim carries no storage request"}

  # coveralls-ignore-stop

  # The 0→N crossing on a file-access app: the pod template gains the
  # WebDAV sidecar, whose world (credential Secret, DAV Service, edge
  # arms) a deploy at gb=0 never minted — land exactly what a deploy at
  # N GB would have. Order mirrors deploy: the Secret precedes the
  # Deployment (the container references it via envFrom), and the edge
  # arms ride the same apply.
  defp maybe_mint_file_access_world(kubeconfig, updated, previous_storage_gb) do
    crossing =
      (is_nil(previous_storage_gb) or previous_storage_gb == 0) and updated.storage_gb > 0

    if crossing and InstanceK8s.file_access?(updated) do
      with {:ok, _secret} <-
             InstanceK8s.maybe_create_file_secret(kubeconfig, updated.namespace, updated),
           {:ok, _service} <-
             InstanceK8s.maybe_create_dav_service(kubeconfig, updated.namespace, updated) do
        InstanceK8s.apply_edge(kubeconfig, updated)
      end
    else
      :ok
    end
  end

  # Cluster truth for env_from_secret (see the moduledoc): an existing
  # app-env Secret keeps the envFrom reference; 404 → none. Any other
  # read failure fails the resize — never guess the pod's env posture.
  defp applied_env(kubeconfig, updated) do
    case Secret.get(kubeconfig, updated.namespace, @env_secret) do
      {:ok, body} ->
        {:ok, body}

      {:error, %Error{reason: :not_found}} ->
        {:ok, %{}}

      # defensive: a non-404 read failure (transport, API error) is an
      # outage-class signal — fail the resize rather than guess the
      # pod's env posture
      {:error, _reason} = error ->
        {:error, error}
    end
  end
end
