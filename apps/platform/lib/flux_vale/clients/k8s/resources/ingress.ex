defmodule FluxVale.Clients.K8s.Resources.Ingress do
  @moduledoc """
  CRUD operations for Traefik IngressRoutes — **only** the `IngressRoute`
  CRD (`traefik.io/v1alpha1`); standard K8s `Ingress` is not supported
  (the whole stack is Traefik: local chart + fleet repo).

  ## Simplified Spec Format

  Subdomain routing (the pod's primary route):

      %{
        subdomain: "my-app",          # Required: subdomain for routing
        service_name: "my-app",       # Required: target service name
        service_port: 80,             # Required: target service port
        tls: true,                    # Optional: enable TLS (default: false)
        tls_secret_name: "wildcard-fluxvale-app-tls",  # Optional: existing TLS secret
        cert_resolver: "letsencrypt"  # Optional: cert-manager resolver (when no tls_secret_name)
      }

  Standalone custom-host routing (one IngressRoute per custom domain —
  custom domains are deferred post-beta, ADR-0031; the path is ported
  ready):

      %{
        host: "myapp.example.com",    # Required: full host (mutually exclusive with subdomain)
        service_name: "app",          # Required: target service name
        service_port: 80,             # Required: target service port
        tls: true,                    # Optional
        tls_secret_name: "myapp-example-com-tls"  # Optional: per-domain cert secret
      }

  When `:host` is present, the route matches `Host(\`<host>\`)` directly and
  `:subdomain`/`:domain` are ignored. The entryPoint is chosen by the `:tls`
  flag alone — `web` (plain HTTP) without it, `websecure` with it — nothing
  here is environment-aware. The local stack has no cert-manager, so
  `tls: true` (with its resolver or secret) is a production-only
  combination; locally the Traefik default cert terminates TLS at the edge.

  **M4 open item**: v1 mirrored the wildcard TLS secret into app namespaces
  with Reflector — dropped in v2. Local M3 doesn't need it (edge-terminated
  TLS); the fleet repo decides wildcard-cert distribution (Traefik default
  cert vs replication) when staging/prod go live.
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified ingress specification"
  @type spec :: %{
          required(:service_name) => String.t(),
          required(:service_port) => integer(),
          optional(:subdomain) => String.t(),
          optional(:host) => String.t(),
          optional(:tls) => boolean(),
          optional(:domain) => String.t(),
          optional(:tls_secret_name) => String.t(),
          optional(:cert_resolver) => String.t()
        }

  @default_cert_resolver "letsencrypt"

  @doc "Creates (server-side-applies) an IngressRoute."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created ingress: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated ingress: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets an IngressRoute by namespace and name."
  @spec get(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, namespace, name) do
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

  @doc "Upserts an IngressRoute — SSA, idempotent."
  @spec upsert(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def upsert(kubeconfig, namespace, name, spec) do
    create(kubeconfig, namespace, name, spec)
  end

  @doc "Deletes an IngressRoute."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted ingress: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Ingress deletion initiated: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 404}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Builds the IngressRoute manifest from the simplified spec.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    tls_enabled = Map.get(spec, :tls, false)
    cert_resolver = Map.get(spec, :cert_resolver, @default_cert_resolver)
    tls_secret_name = Map.get(spec, :tls_secret_name)
    # Local dev's default; production passes an explicit :domain
    domain = Map.get(spec, :domain, "localhost")
    entry_point = if tls_enabled, do: "websecure", else: "web"

    route = %{
      "kind" => "Rule",
      "match" => build_host_match(spec, domain),
      "services" => [
        %{"name" => spec.service_name, "port" => spec.service_port}
      ]
    }

    base_spec = %{"entryPoints" => [entry_point], "routes" => [route]}

    # Prefer tls_secret_name (existing wildcard cert) over cert_resolver
    # (new cert per subdomain — Let's Encrypt rate-limit risk).
    spec_with_tls =
      cond do
        not tls_enabled ->
          base_spec

        tls_secret_name ->
          Map.put(base_spec, "tls", %{"secretName" => tls_secret_name})

        true ->
          Map.put(base_spec, "tls", %{"certResolver" => cert_resolver})
      end

    %{
      "apiVersion" => "traefik.io/v1alpha1",
      "kind" => "IngressRoute",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "spec" => spec_with_tls
    }
  end

  # Escape backslashes first, then backticks — either can inject additional
  # router rules (https://doc.traefik.io/traefik/routing/routers/#rule).
  defp escape_traefik_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
  end

  # :host present (standalone custom-domain route) → match the full host;
  # otherwise compose the primary subdomain route.
  # Dot access raises a clear KeyError if :subdomain is missing, rather than
  # an opaque FunctionClauseError from escape_traefik_value(nil).
  defp build_host_match(spec, domain) do
    case Map.get(spec, :host) do
      host when is_binary(host) and host != "" ->
        "Host(`#{escape_traefik_value(host)}`)"

      _nil ->
        subdomain = spec.subdomain
        "Host(`#{escape_traefik_value(subdomain)}.#{escape_traefik_value(domain)}`)"
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "traefik.io/v1alpha1",
      kind: "IngressRoute"
    )
  end
end
