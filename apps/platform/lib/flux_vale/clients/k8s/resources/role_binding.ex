defmodule FluxVale.Clients.K8s.Resources.RoleBinding do
  @moduledoc """
  CRUD operations for Kubernetes RoleBindings.

  One RoleBinding per instance namespace is the operator pattern's own
  machinery (#73, `deploy/local/k8s/01-platform-rbac.yaml`): it binds the
  platform's service account to the `fluxvale-platform-workload`
  ClusterRole **inside that namespace only** — workload permissions exist
  solely where instances live, never cluster-wide.

  ## Simplified Spec Format

      %{
        service_account: "fluxvale-platform",             # Required: subject SA name
        service_account_namespace: "fluxvale-dev",        # Required: subject SA namespace
        role: "fluxvale-platform-workload"                # Required: ClusterRole to bind
      }
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified role binding specification"
  @type spec :: %{
          required(:service_account) => String.t(),
          required(:service_account_namespace) => String.t(),
          required(:role) => String.t()
        }

  @doc "Creates (server-side-applies) a RoleBinding from a simplified spec."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created role binding: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated role binding: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets a RoleBinding by namespace and name."
  @spec get(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, namespace, name) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Deletes a RoleBinding."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted role binding: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Builds the RoleBinding manifest from the simplified spec.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    %{
      "apiVersion" => "rbac.authorization.k8s.io/v1",
      "kind" => "RoleBinding",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "roleRef" => %{
        "apiGroup" => "rbac.authorization.k8s.io",
        "kind" => "ClusterRole",
        "name" => spec.role
      },
      "subjects" => [
        %{
          "kind" => "ServiceAccount",
          "name" => spec.service_account,
          "namespace" => spec.service_account_namespace
        }
      ]
    }
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "rbac.authorization.k8s.io/v1",
      kind: "RoleBinding"
    )
  end
end
