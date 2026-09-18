defmodule FluxVale.Clients.K8s.Resources.Namespace do
  @moduledoc """
  CRUD operations for Kubernetes Namespaces.

  A namespace is an Instance's isolation boundary — one `fluxvale-app-<id>`
  namespace per customer workload (ADR-0005). Standard label
  `app.kubernetes.io/managed-by: fluxvale` on everything the platform owns.
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified namespace specification"
  @type spec :: %{
          optional(:labels) => map()
        }

  @doc "Lists all namespaces in the cluster."
  @spec list(Kubereq.Kubeconfig.t()) :: {:ok, list(map())} | {:error, Error.t()}
  def list(kubeconfig) do
    req = create_req(kubeconfig)

    case Kubereq.list(req) do
      {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
        {:ok, items}

      # Malformed 200 body (broken proxy/server) — a missing or non-list
      # "items" must not reach from_response/1, which raises on 2xx.
      {:ok, %{status: 200, body: body}} ->
        {:error, Error.validation_error("Malformed NamespaceList response: #{inspect(body)}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Gets a namespace by name. `{:error, %Error{reason: :not_found}}` if absent.
  """
  @spec get(Kubereq.Kubeconfig.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, name) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, name) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Creates (server-side-applies) a namespace with optional extra labels.

  `{:error, %Error{reason: :already_exists}}` only on genuine API 409s —
  apply is idempotent for identical manifests.
  """
  @spec create(Kubereq.Kubeconfig.t(), String.t(), spec()) :: {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, name, spec \\ %{}) do
    req = create_req(kubeconfig)
    manifest = build_manifest(name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created namespace: #{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Namespace already exists: #{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Builds a Namespace manifest: `managed-by` label merged with `spec[:labels]`.
  """
  @spec build_manifest(String.t(), spec()) :: map()
  def build_manifest(name, spec) do
    labels = Map.merge(%{"app.kubernetes.io/managed-by" => "fluxvale"}, spec[:labels] || %{})

    %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{
        "name" => name,
        "labels" => labels
      }
    }
  end

  @doc """
  Deletes a namespace — and everything in it.
  """
  @spec delete(Kubereq.Kubeconfig.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted namespace: #{name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Namespace deletion initiated: #{name}")
        :ok

      {:ok, %{status: 404}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Checks namespace existence. `{:ok, boolean()}` or `{:error, %Error{}}`."
  @spec exists?(Kubereq.Kubeconfig.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def exists?(kubeconfig, name) do
    case get(kubeconfig, name) do
      {:ok, _namespace} -> {:ok, true}
      {:error, %Error{reason: :not_found}} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Gets the namespace phase: `"Active"`, `"Terminating"`, or `nil`.
  """
  @spec status(Kubereq.Kubeconfig.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, Error.t()}
  def status(kubeconfig, name) do
    case get(kubeconfig, name) do
      {:ok, namespace} -> {:ok, get_in(namespace, ["status", "phase"])}
      {:error, error} -> {:error, error}
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "v1", kind: "Namespace")
  end
end
