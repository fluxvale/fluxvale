defmodule FluxVale.Clients.K8s.Resources.Service do
  @moduledoc """
  CRUD operations for Kubernetes Services.

  `ClusterIP` services front the app pods inside the namespace; Traefik
  IngressRoutes expose them externally. An `ExternalName` variant
  (#203, ADR-0036) aliases a DNS name elsewhere — the instance
  namespace's `wake` service points at the platform, so a sleeping
  instance's edge route can hand visitors to the wake endpoint without
  any cross-namespace Traefik reference (the provider flag
  `allowExternalNameServices` gates Traefik's side).

  ## Simplified Spec Format

      %{
        port: 80,                      # Required: service port
        target_port: 8080,             # Optional: container port (default: port)
        selector: %{"app" => "name"}   # Required: pod selector labels
      }

  ExternalName (#203):

      %{
        external_name: "fluxvale-platform.fluxvale-dev.svc.cluster.local",
        port: 4000
      }
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified service specification"
  @type spec :: %{
          required(:port) => integer(),
          optional(:target_port) => integer(),
          optional(:selector) => map(),
          optional(:external_name) => String.t()
        }

  @doc """
  Creates (server-side-applies) a Service. An `external_name` (#203) is
  validated as a DNS name first — an invalid value gets
  `{:error, %Error{reason: :invalid_spec}}` rather than a dead alias
  (the Ingress posture: config-derived values still fail loudly).
  """
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    external_name = Map.get(spec, :external_name)

    if external_name != nil and not valid_dns_name?(external_name) do
      {:error, Error.invalid_spec("Not a valid DNS name: #{inspect(external_name)}")}
    else
      do_create(kubeconfig, namespace, name, spec)
    end
  end

  defp do_create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created service: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated service: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets a service by namespace and name."
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

  @doc "Upserts a service — SSA, idempotent."
  @spec upsert(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def upsert(kubeconfig, namespace, name, spec) do
    create(kubeconfig, namespace, name, spec)
  end

  @doc "Deletes a service."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted service: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Service deletion initiated: #{namespace}/#{name}")
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
  Builds the ClusterIP (or ExternalName, #203) Service manifest from
  the simplified spec.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    port = spec.port
    target_port = Map.get(spec, :target_port, port)

    base = %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      }
    }

    case Map.get(spec, :external_name) do
      external_name when is_binary(external_name) ->
        Map.put(base, "spec", external_name_spec(external_name, port))

      _nil ->
        Map.put(base, "spec", %{
          "type" => "ClusterIP",
          "selector" => spec.selector,
          "ports" => [
            %{"port" => port, "targetPort" => target_port, "protocol" => "TCP"}
          ]
        })
    end
  end

  defp external_name_spec(external_name, port) do
    %{
      "type" => "ExternalName",
      "externalName" => external_name,
      "ports" => [%{"port" => port, "protocol" => "TCP"}]
    }
  end

  # Same DNS-label shape the Ingress builder enforces: dot-separated
  # labels, alnum + inner hyphens. The external_name is config-derived,
  # not user input — this is fail-loudly defense, not a trust boundary.
  defp valid_dns_name?(value) when is_binary(value) do
    labels = String.split(value, ".")
    Enum.all?(labels, &Regex.match?(~r/^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, &1))
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "v1", kind: "Service")
  end
end
