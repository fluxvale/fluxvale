defmodule FluxVale.Infrastructure.Operations.ReadFileAccessCredential do
  @moduledoc """
  Reads a file-access Instance's WebDAV credential (username +
  password) from the namespace's `file-access` Secret — the instance
  page's reveal path (#190, ADR-0035).

  The Secret is the credential's only home: generated at deploy,
  get-or-created across retries, never copied into the platform DB. A
  reveal is therefore a live cluster read, and its outcomes are UI
  copy: `{:error, :not_deployed}` before the first deploy creates the
  Secret, `{:error, :not_found}` for a Secret that isn't there (torn
  down, or an instance predating file access).

  Ownership is upstream: the caller holds an actor-authorized Instance
  (the page's mount read); this operation makes no policy decision of
  its own.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @file_secret "file-access"
  @username_key "RCLONE_USER"
  @password_key "RCLONE_PASS"

  @typedoc "The instance's WebDAV credential"
  @type credential :: %{username: String.t(), password: String.t()}

  @spec call(map()) :: {:ok, credential()} | {:error, :not_deployed | :not_found | term()}
  def call(%{file_access: true, namespace: namespace} = instance) when is_binary(namespace) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} -> read_secret(kubeconfig, namespace)
      {:error, error} -> {:error, error}
    end
  end

  # Never-deployed (namespace nil): there is no Secret to read yet.
  def call(%{file_access: true, namespace: nil}), do: {:error, :not_deployed}

  # A non-file-access instance has no credential by construction — the
  # page never renders the panel, this arm is the API-surface guard.
  def call(_instance), do: {:error, :not_found}

  defp read_secret(kubeconfig, namespace) do
    case Secret.get_data(kubeconfig, namespace, @file_secret) do
      {:ok, %{@username_key => username, @password_key => password}} ->
        {:ok, %{username: username, password: password}}

      {:ok, _malformed} ->
        # Defensive: the platform is the Secret's only writer; a partial
        # read means out-of-band tampering (pinned by the test below)
        {:error, :malformed}

      {:error, %Error{reason: :not_found}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end
end
