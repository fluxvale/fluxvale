defmodule FluxVale.Infrastructure.Operations.ClusterFootprint do
  @moduledoc """
  The cluster arms the two re-apply paths share: the stopped-first
  re-allocation (#493) and #250's online storage-only growth. One home so
  the claim's widening rule and the file-access world cannot fork between
  them.

  The claim only ever widens: the applied size is `max(row, live)`, because
  a partial failure leaves the live claim wider than the row — a divergence
  that heals on the next apply to a target ≥ the live claim, instead of
  wedging every retry below it. The 0→N crossing on a file-access app
  mints the sidecar's world — the credential Secret (get-or-create: a
  retrying apply never rotates the owner's rclone credential), the DAV
  Service, and the edge arms — exactly what a deploy at N GB would have
  minted (a deploy at gb=0 minted none of them).

  The deployment re-apply keeps replicas at the live claim and reads the
  cluster's app-env Secret for the envFrom posture — never a recompute
  from the row: deploy's env is exposure-dependent and deploy-time-frozen,
  so what the pod already references is what the re-apply keeps.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @env_secret "app-env"
  @claim "app-data"

  @doc """
  Re-applies the data PVC when storage moved: unchanged skips the claim
  entirely; 0→N or a grow applies `max(row, live)` (the capability gate is
  the caller guard's). `previous_storage_gb` is the pre-action row value —
  nil reads as the mint arm.
  """
  @spec apply_storage(Kubereq.Kubeconfig.t(), Instance.t(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def apply_storage(_kubeconfig, %Instance{storage_gb: gb}, gb), do: :ok

  def apply_storage(kubeconfig, %Instance{} = updated, _previous_storage_gb) do
    apply_claim(kubeconfig, updated)
  end

  @doc """
  Whether the apply mints the file-access sidecar's world: the 0→N storage
  crossing on an app that declared file access.
  """
  @spec mints_file_access_world?(Instance.t(), non_neg_integer() | nil) :: boolean()
  def mints_file_access_world?(%Instance{} = updated, previous_storage_gb) do
    crossing?(updated, previous_storage_gb) and InstanceK8s.file_access?(updated)
  end

  @doc """
  The 0→N crossing's sidecar world (see the moduledoc); a no-op otherwise.
  Order mirrors deploy: the Secret precedes the Deployment (envFrom).
  """
  @spec maybe_mint_file_access_world(
          Kubereq.Kubeconfig.t(),
          Instance.t(),
          non_neg_integer() | nil
        ) :: :ok | {:error, term()}
  def maybe_mint_file_access_world(kubeconfig, %Instance{} = updated, previous_storage_gb) do
    if mints_file_access_world?(updated, previous_storage_gb) do
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

  @doc """
  Re-applies the Deployment at the row's footprint, replicas following the
  live claim (a racing start's scale-to-one survives; a stopped-first 0 is
  the floor).
  """
  @spec apply_deployment(Kubereq.Kubeconfig.t(), Instance.t()) :: :ok | {:error, term()}
  def apply_deployment(kubeconfig, %Instance{} = updated) do
    with {:ok, env} <- applied_env(kubeconfig, updated),
         {:ok, deployment} <- deployment_spec(kubeconfig, updated, env),
         {:ok, _deployment} <-
           Deployment.create(kubeconfig, updated.namespace, "app", deployment) do
      :ok
    end
  end

  defp crossing?(%Instance{} = updated, previous_storage_gb) do
    (is_nil(previous_storage_gb) or previous_storage_gb == 0) and updated.storage_gb > 0
  end

  # Replicas follow the live claim (see the moduledoc): the racing start's
  # scale-to-one is honest, the stopped-first 0 is the floor.
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

  # "20Gi" → 20. A claim whose size we cannot parse is an outage-class
  # signal — fail the apply rather than re-apply a size that could shrink a
  # live claim.
  defp parse_claim_gb(size) when is_binary(size) do
    trimmed = String.trim_trailing(size, "Gi")

    case Integer.parse(trimmed) do
      {gb, ""} -> {:ok, gb}
      _garbage -> {:error, "cannot parse the live claim's size: #{inspect(size)}"}
    end
  end

  # coveralls-ignore-start - defensive: a claim without a size string is
  # not a shape the API server produces (requests.storage is required on a
  # bound claim); the arm keeps the function total.
  defp parse_claim_gb(_missing), do: {:error, "the live claim carries no storage request"}
  # coveralls-ignore-stop

  # Cluster truth for env_from_secret (see the moduledoc): an existing
  # app-env Secret keeps the envFrom reference; 404 → none. Any other read
  # failure fails the apply — never guess the pod's env posture.
  defp applied_env(kubeconfig, updated) do
    case Secret.get(kubeconfig, updated.namespace, @env_secret) do
      {:ok, body} ->
        {:ok, body}

      {:error, %Error{reason: :not_found}} ->
        {:ok, %{}}

      # defensive: a non-404 read failure (transport, API error) is an
      # outage-class signal — fail the apply rather than guess the pod's
      # env posture
      {:error, _reason} = error ->
        {:error, error}
    end
  end
end
