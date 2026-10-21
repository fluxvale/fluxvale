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
        cert_resolver: "letsencrypt", # Optional: cert-manager resolver (when no tls_secret_name)
        path_prefix: "/dav"           # Optional: match only this sub-path (#190)
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

  **Wildcard distribution — resolved with #116**: the fleet issues
  `*.fluxvale.app` into the traefik namespace and wires a Traefik
  default TLSStore, so the edge serves the wildcard for every route
  without an explicit cert — exactly the shape `tls: true` alone
  builds. v1's per-namespace Reflector mirror stays dropped: local
  runs edge-terminated on Traefik's fallback cert, deployed envs on
  the wildcard; no secret ever replicates into app namespaces.
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
          optional(:cert_resolver) => String.t(),
          optional(:path_prefix) => String.t()
        }

  @default_cert_resolver nil

  # DNS-name shape: dot-separated labels, alnum + inner hyphens, 1-63 chars
  # each. Rejects backticks, backslashes, spaces — anything that would make
  # a dead or injectable Traefik rule. \z (not $): a trailing newline must
  # not slip through ($ matches before a final \n in PCRE).
  @dns_label ~r/^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/

  # Path-prefix shape (#190): starts at root, URL-path characters only
  # (alnum, hyphen, underscore, dot, inner slashes) — same injection
  # posture as @dns_label: a backtick or backslash here is a dead or
  # hostile rule, rejected before it reaches Traefik. Anchored at both
  # ends — junk ahead of a clean tail (`") || PathPrefix(\`/evil`) is
  # still junk.
  @path_prefix ~r/\A\/[A-Za-z0-9._\/-]*\z/

  @doc """
  Creates (server-side-applies) an IngressRoute.

  Host-ish values (`:host`, `:subdomain`, `:domain`) are validated as DNS
  names first — an invalid value gets `{:error, %Error{reason: :invalid_spec}}`
  rather than a Traefik rule that's escaped-but-syntactically-dead. A
  `:path_prefix` (same hostname, sub-path route — the file-access `/dav`,
  #190) gets the same pre-validation.
  """
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    host_values = [
      Map.get(spec, :host),
      Map.get(spec, :subdomain),
      Map.get(spec, :domain)
    ]

    invalid_host =
      Enum.find(host_values, fn value -> value != nil and not valid_dns_name?(value) end)

    path_prefix = Map.get(spec, :path_prefix)

    invalid_path? = path_prefix != nil and not Regex.match?(@path_prefix, path_prefix)

    cond do
      invalid_host ->
        {:error, Error.invalid_spec("Not a valid DNS name: #{inspect(invalid_host)}")}

      invalid_path? ->
        {:error, Error.invalid_spec("Not a valid path prefix: #{inspect(path_prefix)}")}

      true ->
        do_create(kubeconfig, namespace, name, spec)
    end
  end

  defp do_create(kubeconfig, namespace, name, spec) do
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

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

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

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

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
    # (new cert per subdomain — Let's Encrypt rate-limit risk). Neither →
    # no tls stanza at all: the edge's default cert terminates TLS (the
    # local stack's shape, `deploy/local/k8s/15-ingressroute.yaml`).
    spec_with_tls =
      cond do
        not tls_enabled ->
          base_spec

        tls_secret_name ->
          Map.put(base_spec, "tls", %{"secretName" => tls_secret_name})

        cert_resolver ->
          Map.put(base_spec, "tls", %{"certResolver" => cert_resolver})

        true ->
          base_spec
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
  # Defense in depth: create/4 rejects non-DNS values before we get here.
  defp escape_traefik_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
  end

  # :host present (standalone custom-domain route) → match the full host;
  # otherwise compose the primary subdomain route. A :path_prefix
  # (#190) narrows the match to that sub-path on the same hostname.
  # Dot access raises a clear KeyError if :subdomain is missing, rather than
  # an opaque FunctionClauseError from escape_traefik_value(nil).
  defp build_host_match(spec, domain) do
    host_match =
      case Map.get(spec, :host) do
        host when is_binary(host) and host != "" ->
          "Host(`#{escape_traefik_value(host)}`)"

        _nil ->
          subdomain = spec.subdomain
          "Host(`#{escape_traefik_value(subdomain)}.#{escape_traefik_value(domain)}`)"
      end

    case Map.get(spec, :path_prefix) do
      nil -> host_match
      prefix -> "#{host_match} && PathPrefix(`#{prefix}`)"
    end
  end

  defp valid_dns_name?(value) when is_binary(value) do
    labels = String.split(value, ".")
    Enum.all?(labels, &Regex.match?(@dns_label, &1))
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "traefik.io/v1alpha1",
      kind: "IngressRoute"
    )
  end
end
