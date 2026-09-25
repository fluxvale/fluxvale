defmodule FluxVale.Clients.K8s.Resources.NetworkPolicy do
  @moduledoc """
  CRUD operations for Kubernetes NetworkPolicies.

  Per-instance-namespace ingress isolation is a product primitive
  (ADR-0005): default-deny inbound, then re-admit only same-namespace
  traffic and the edge proxy. Egress stays open in M3 — catalog apps
  (Forgejo: git over HTTPS, mail) need arbitrary outbound; tightening
  egress is post-beta polish.

  ## Simplified Spec Format

      %{
        ingress_from_namespaces: ["traefik"]  # Required: namespaces allowed
                                              # to open inbound connections
      }

  Same-namespace ingress is always allowed (not part of the spec — an app
  talking to its own sidecars/replicas is not a policy question).
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified network policy specification"
  @type spec :: %{
          required(:ingress_from_namespaces) => [String.t()]
        }

  @doc "Creates (server-side-applies) a NetworkPolicy from a simplified spec."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created network policy: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated network policy: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets a NetworkPolicy by namespace and name."
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

  @doc "Deletes a NetworkPolicy."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted network policy: #{namespace}/#{name}")
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
  Builds the NetworkPolicy manifest from the simplified spec.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    external_sources =
      Enum.map(spec.ingress_from_namespaces, fn ns ->
        %{"namespaceSelector" => %{"matchLabels" => %{"kubernetes.io/metadata.name" => ns}}}
      end)

    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "spec" => %{
        # Empty selector = every pod in the namespace; one policy governs all.
        "podSelector" => %{},
        "policyTypes" => ["Ingress"],
        "ingress" => [
          %{"from" => [%{"podSelector" => %{}} | external_sources]}
        ]
      }
    }
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "networking.k8s.io/v1",
      kind: "NetworkPolicy"
    )
  end
end
