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

  @typedoc """
  Simplified network policy specification.

  `ingress_from_namespaces` admits *every* pod in each listed namespace.
  Use `ingress_from_sources` instead when the admitted pods within a
  namespace must be narrowed — several tenants' pods share the access
  namespace, so org A's gateway must reach org A's app and nothing else.
  The two forms are mutually exclusive in practice; sources wins if both
  are present.

  ## Shapes

  `network_policy_spec/1` emits exactly one of the two, never both:

  - **No gateway attached** — `%{ingress_from_namespaces: [...]}`: the
    plain exposure floor (the edge namespace for `:public`, `[]` for
    `:private`, which is the same-namespace-only denial).
  - **A gateway attached** — `%{ingress_from_sources: [...]}`: the
    exposure floor as whole-namespace peers plus one narrowed peer per
    attached gateway (`namespace` + `match_labels`).
  """
  @type spec :: %{
          optional(:ingress_from_namespaces) => [String.t()],
          optional(:ingress_from_sources) => [source()]
        }

  @typedoc """
  One admitted peer: a namespace, optionally narrowed to pods carrying
  every one of `match_labels`.
  """
  @type source :: %{
          required(:namespace) => String.t(),
          optional(:match_labels) => %{optional(String.t()) => String.t()}
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
      spec
      |> sources()
      |> Enum.map(&source_manifest/1)

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

  # `ingress_from_sources` is the narrowing form; `ingress_from_namespaces`
  # the whole-namespace one the single-tenant callers use.
  defp sources(%{ingress_from_sources: sources}) when is_list(sources), do: sources

  defp sources(%{ingress_from_namespaces: namespaces}) do
    Enum.map(namespaces, &%{namespace: &1})
  end

  defp source_manifest(%{namespace: ns} = source) do
    peer = %{
      "namespaceSelector" => %{"matchLabels" => %{"kubernetes.io/metadata.name" => ns}}
    }

    case Map.get(source, :match_labels) do
      labels when is_map(labels) and labels != %{} ->
        Map.put(peer, "podSelector", %{"matchLabels" => labels})

      _whole_namespace ->
        peer
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "networking.k8s.io/v1",
      kind: "NetworkPolicy"
    )
  end
end
