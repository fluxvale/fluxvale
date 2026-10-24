defmodule FluxVale.Infrastructure.Operations.ReadBackupCredential do
  @moduledoc """
  Reads an Instance's restic repo password from the namespace's
  `backup-config` Secret — the backups panel's reveal path (#222,
  ADR-0037 §4).

  The Secret is the credential's only home: generated at first save,
  preserved byte-for-byte across every re-save, never copied into the
  platform DB. The reveal is therefore a live cluster read, and its
  outcomes are UI copy: `{:error, :not_deployed}` before the first
  deploy creates a namespace, `{:error, :not_found}` when the Secret
  isn't there (never saved, or the namespace went), and `:malformed`
  for a Secret written out-of-band.

  The password is not rotated here and never derived from the S3 secret
  key: it is the repo's identity, and the panel's copy is the seed of
  restoring into a new instance (ADR-0037 §5's next slice).

  Ownership is upstream: the caller holds an actor-authorized Instance
  (the page's mount read); this operation makes no policy decision of
  its own.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @secret_name "backup-config"
  @password_key "RESTIC_PASSWORD"

  @typedoc "The instance's backup repo credential"
  @type credential :: %{repo_password: String.t()}

  @spec call(map()) ::
          {:ok, credential()} | {:error, :not_deployed | :not_found | :malformed | term()}
  def call(%{namespace: namespace} = instance) when is_binary(namespace) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} -> read_secret(kubeconfig, namespace)
      {:error, error} -> {:error, error}
    end
  end

  # Never deployed (namespace nil): there is no Secret to read yet.
  def call(_instance), do: {:error, :not_deployed}

  defp read_secret(kubeconfig, namespace) do
    case Secret.get_data(kubeconfig, namespace, @secret_name) do
      {:ok, %{@password_key => password}} when is_binary(password) and password != "" ->
        {:ok, %{repo_password: password}}

      # Defensive: the platform is the Secret's only writer; a partial
      # read means out-of-band tampering or a truncated write.
      {:ok, _malformed} ->
        {:error, :malformed}

      {:error, %Error{reason: :not_found}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end
end
