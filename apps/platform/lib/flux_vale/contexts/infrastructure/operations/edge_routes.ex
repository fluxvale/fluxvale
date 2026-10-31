defmodule FluxVale.Infrastructure.Operations.EdgeRoutes do
  @moduledoc """
  The instance's edge routes in their two modes (#203, ADR-0036) — the
  one seam that knows how a sleeping instance's traffic reaches the
  wake endpoint and how a woken one's traffic reaches the app again:

  - **serving**: `Host(slug.domain)` → the app Service, with the
    activity-beacon Middleware attached (`forwardAuth` → the
    platform's touch endpoint — the edge-written idle marker).
  - **wake**: same match → the namespace's `wake` ExternalName Service
    (→ the platform), with the wake-marker Middleware attached (a
    request header naming the instance — no hostname parsing).

  The **access arms** (ADR-0040 §7) are the same two modes on the
  private path: one Host-keyed IngressRoute per `InstanceHostname` row
  of the instance, on Traefik's `access` entrypoint (the gateway's
  raw-443 tunnel terminates there; the platform names the entrypoint,
  never a port). Serving targets the app Service with the beacon
  attached; wake targets the platform through the same `wake`
  ExternalName pattern with the path rewritten to
  `/internal/access/<gateway>/<instance>/…` — the PAIR IN THE PATH is
  the whole authorization (#301's contract, carried verbatim through
  the Traefik hop). TLS comes from the default TLSStore for platform
  domains (the fleet wildcard, #116) and the domain's issued-wildcard
  Secret for verified custom ones — an unverified custom domain never
  routes.

  Deploys land serving; `SleepInstance` flips both routes to wake; the
  first request after `:running` flips them back (the wake endpoint's
  restore — the visitor's reload lands on the app). All applies are
  SSA-idempotent, so every mode-apply re-applies its full object set
  (routes + middlewares + the wake Service): instances deployed before
  #203 converge on their first sleep or restore.

  Consumed by DeployInstance (initial serving set), SleepInstance
  (wake flip), and the wake endpoint (restore flip); on the private
  path by AttachInstance/DetachInstance (mint/remove per the pairing
  row) and SetExposure's toggle limbs — the specs are the
  shared boundary, so they live here rather than being copied many
  ways (the operations-own-their-constants rule's sanctioned exception:
  this IS the one owner).
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname

  require Ash.Query
  require Logger

  @app_ingress "app-ingress"
  @dav_ingress "app-dav"
  @beacon_middleware "fluxvale-activity"
  @wake_middleware "fluxvale-wake"
  @wake_service "wake"
  # The access edge (ADR-0040 §7): the entrypoint is a NAME we mint into
  # the IngressRoute spec — the fleet frames the entrypoint itself; this
  # module never knows a port.
  @access_entrypoint "access"
  # The access-wake rewrite middleware: one per instance namespace (the
  # namespace IS the instance), carrying the pair-in-the-path rewrite
  # the wake route references by name.
  @access_wake_middleware "fluxvale-access-wake"
  # The instance wake marker: names the instance for the wake endpoint. Custom
  # header names are invisible to apps (Traefik strips nothing, but the
  # app Service never sees wake-mode traffic) and unguessable together
  # with the UUID value.
  @instance_header "X-FluxVale-Instance"

  @doc """
  The wake-marker header name — EdgeRoutes mints it into the wake
  middleware; the wake endpoint reads it. One owner, no drift.
  """
  @spec instance_header() :: String.t()
  def instance_header, do: @instance_header

  @doc """
  Applies the serving-mode object set: beacon Middleware + app route
  (+ `/dav` route for file-access instances). `:ok` or the first
  `{:error, Error.t()}`.

  A private instance never serves publicly (#265): the call converges
  on the private posture (delete any public routes) instead of minting
  one — callers stay exposure-blind.
  """
  @spec apply_serving(Kubereq.Kubeconfig.t(), Instance.t()) ::
          :ok | {:error, term()}
  def apply_serving(kubeconfig, %{exposure: :private} = instance) do
    apply_private(kubeconfig, instance)
  end

  def apply_serving(kubeconfig, instance) do
    serving_apply(kubeconfig, instance)
  end

  @doc """
  Applies the wake-mode object set: the dormant wake targets (see
  `ensure_wake_targets/2`) plus the wake-mode app route (+ `/dav`).
  Called from the sleep path — the app Deployment is already at 0 by
  then, so visitors must land on the wake endpoint, not a
  connectionless Service.

  A private instance has no public route to flip (#265): the call
  converges on the private posture — a sleeping private instance
  stays asleep because nothing at the edge can reach it.
  """
  @spec apply_wake(Kubereq.Kubeconfig.t(), Instance.t()) :: :ok | {:error, term()}
  def apply_wake(kubeconfig, %{exposure: :private} = instance) do
    apply_private(kubeconfig, instance)
  end

  def apply_wake(kubeconfig, instance) do
    wake_apply(kubeconfig, instance)
  end

  @doc """
  The public posture's routes in an explicit mode — SetExposure's
  compensating-restore seam (PR #267 review finding 3): the row is
  mid-rollback (the record in hand still names the failed direction),
  so the exposure dispatch of `apply_serving/2`/`apply_wake/2` must
  not re-route it. Every other caller uses the dispatched entries.
  """
  @spec apply_public(Kubereq.Kubeconfig.t(), Instance.t(), :serving | :wake) ::
          :ok | {:error, term()}
  def apply_public(kubeconfig, instance, :serving), do: serving_apply(kubeconfig, instance)
  def apply_public(kubeconfig, instance, :wake), do: wake_apply(kubeconfig, instance)

  @doc """
  The private posture (#265): NO route on the public entrypoint — any
  existing app (+ `/dav`) IngressRoute is deleted, none minted. The
  wake targets are deliberately not minted either: without a route
  they are unreachable, and a private instance has nothing to wake.
  Idempotent (a missing route is already the posture); `:ok` or the
  first `{:error, Error.t()}`.
  """
  @spec apply_private(Kubereq.Kubeconfig.t(), Instance.t()) :: :ok | {:error, term()}
  def apply_private(kubeconfig, instance) do
    namespace = instance.namespace

    with :ok <- safe_delete_route(kubeconfig, namespace, @app_ingress) do
      maybe_delete_dav(kubeconfig, instance)
    end
  end

  @doc """
  The access edge's serving set (ADR-0040 §7): one Host-keyed
  IngressRoute per `InstanceHostname` row of the instance — `Host(
  <label>.<domain>)` on the `access` entrypoint, the app Service behind
  it, the beacon attached (the idle clock works on the private path;
  the beacon is hostname-agnostic). TLS rides the default TLSStore for
  a platform domain (the fleet wildcard, #116 — no secretName) and the
  domain's issued-wildcard Secret for a verified custom one; an
  unverified custom domain never routes (skip + log).

  The dormant access-wake targets ride along (#203's lesson: the first
  sleep's flip must only rewrite a route Traefik already watches — a
  first flip that minted them too would leave a window where the
  rewritten route references unobserved objects), and the beacon
  Middleware lands first (the public serving arm's own order: routes
  reference it by name, so it must exist before they do). Idempotent
  (SSA); `:ok` or the first `{:error, Error.t()}`.
  """
  @spec apply_access_serving(Kubereq.Kubeconfig.t(), map(), Instance.t()) ::
          :ok | {:error, term()}
  def apply_access_serving(kubeconfig, gateway, instance) do
    with {:ok, _beacon} <-
           Middleware.create(
             kubeconfig,
             instance.namespace,
             @beacon_middleware,
             beacon_spec(instance)
           ),
         :ok <- ensure_access_wake_targets(kubeconfig, gateway, instance) do
      apply_hostname_routes(kubeconfig, gateway, instance, :serving)
    end
  end

  @doc """
  The access edge's wake set: the same hostnames, retargeted at the
  platform through the SAME ExternalName `wake` Service the public wake
  mode uses, with the per-instance rewrite middleware in front —
  `^/(.*)` → `/internal/access/<gateway>/<instance>/$1`. The pair in the
  path is the whole authorization (the #301 contract): the wake route
  grants nothing the pairing row doesn't, and the endpoint's identical-404
  miss posture answers everything else. The beacon is NOT attached in
  wake mode (mirror the public wake arm — nothing is being forwarded).
  Idempotent (SSA); `:ok` or the first `{:error, Error.t()}`.
  """
  @spec apply_access_wake(Kubereq.Kubeconfig.t(), map(), Instance.t()) ::
          :ok | {:error, term()}
  def apply_access_wake(kubeconfig, gateway, instance) do
    with :ok <- ensure_access_wake_targets(kubeconfig, gateway, instance) do
      apply_hostname_routes(kubeconfig, gateway, instance, :wake)
    end
  end

  @doc """
  The arm for an instance's CURRENT status: `:running` serves, anything
  wake-shaped stays wake (the ServeConfig.target_for decision shape — a
  `:starting` instance gets the waking page, not a connectionless
  Service). One owner for the dispatch — the attach, deploy, toggle,
  janitor, and wake-flip callers must not fork it.
  """
  @spec apply_access_for_status(Kubereq.Kubeconfig.t(), map(), Instance.t()) ::
          :ok | {:error, term()}
  def apply_access_for_status(kubeconfig, gateway, %{status: :running} = instance) do
    apply_access_serving(kubeconfig, gateway, instance)
  end

  def apply_access_for_status(kubeconfig, gateway, instance) do
    apply_access_wake(kubeconfig, gateway, instance)
  end

  @doc """
  Removes the instance's access edge: every access IngressRoute (by
  hostname row — the rows ARE the record of what was minted) plus the
  access-wake Middleware. 404s tolerated — a missing object is the
  posture already holding (the safe_delete stance), so the call is
  idempotent. `:ok` or the first `{:error, Error.t()}`.
  """
  @spec apply_access_none(Kubereq.Kubeconfig.t(), Instance.t()) :: :ok | {:error, term()}
  def apply_access_none(kubeconfig, instance) do
    with :ok <- delete_access_routes(kubeconfig, instance) do
      safe_delete_middleware(kubeconfig, instance.namespace, @access_wake_middleware)
    end
  end

  # The dormant access-wake targets: the `wake` ExternalName Service
  # (shared with the public wake mode — one pattern, one platform
  # address) and the rewrite middleware carrying THIS pairing's path.
  # Applied at serving-time too, so a deploy pre-creates everything the
  # first sleep's flip references (#203).
  defp ensure_access_wake_targets(kubeconfig, gateway, instance) do
    with {:ok, _service} <-
           Service.create(kubeconfig, instance.namespace, @wake_service, wake_service_spec()),
         {:ok, _rewrite} <-
           Middleware.create(
             kubeconfig,
             instance.namespace,
             @access_wake_middleware,
             access_wake_rewrite_spec(gateway, instance)
           ) do
      :ok
    end
  end

  # The rewrite IS the authorization's carrier: the visitor's path is
  # re-pointed at the platform's access prefix with the (gateway,
  # instance) pair spliced in — exactly the pair the AccessWake
  # controller gates on (serve's asleep target, Traefik-flavored).
  defp access_wake_rewrite_spec(gateway, instance) do
    %{
      replace_path_regex: %{
        regex: "^/(.*)",
        replacement: "/internal/access/#{gateway.id}/#{instance.id}/$1"
      }
    }
  end

  # One route per hostname row; the first failure stops the walk (a
  # half-minted set is the caller's compensation problem, never a
  # silent partial posture). The gateway rides along for the routes'
  # ownership labels (Design 2: a future orphan is discoverable).
  defp apply_hostname_routes(kubeconfig, gateway, instance, mode) do
    instance.id
    |> hostname_rows()
    |> Enum.reduce_while(:ok, fn hostname, :ok ->
      case apply_hostname_route(kubeconfig, gateway, instance, hostname, mode) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp apply_hostname_route(kubeconfig, gateway, instance, hostname, mode) do
    domain = hostname.access_domain

    if domain.organization_id != instance.organization_id do
      # Belt (the S3 surface): re-homing may move rows between domains;
      # a hostname under ANOTHER org's domain must never route. The mint
      # paths cannot produce this today — if a row ever says otherwise,
      # it is out-of-band, and skipping (logged) is the fail-closed
      # answer.
      Logger.warning(
        "Access edge: skipping hostname #{hostname.label}.#{domain.domain} — its domain " <>
          "belongs to another organization (row out of band)"
      )

      :ok
    else
      mint_hostname_route(kubeconfig, gateway, instance, hostname, mode, domain)
    end
  end

  defp mint_hostname_route(kubeconfig, gateway, instance, hostname, mode, domain) do
    case access_tls_secret(kubeconfig, domain, instance) do
      :skip ->
        :ok

      {:ok, tls_secret} ->
        spec = access_route_spec(gateway, hostname, mode, tls_secret)

        case Ingress.create(kubeconfig, instance.namespace, access_route_name(hostname), spec) do
          {:ok, _route} -> :ok
          {:error, _error} = error -> error
        end
    end
  end

  # The rows drive the routes (InstanceHostname is the one source of
  # truth for "which hostnames exist", S1): query, never a parallel
  # naming scheme. System seam — the edge runs actorless, so the read
  # is `authorize?: false` (the provider's routes_for posture).
  defp hostname_rows(instance_id) do
    InstanceHostname
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.Query.load(:access_domain)
    |> Ash.read!(authorize?: false)
  end

  defp access_route_spec(gateway, hostname, mode, tls_secret) do
    domain = hostname.access_domain

    base = %{
      host: "#{hostname.label}.#{domain.domain}",
      entrypoint: @access_entrypoint,
      tls: true,
      middlewares: access_middlewares(mode),
      # Ownership labels (Design 2): managed-by rides the builder's
      # default; the pairing dimensions make any future orphan
      # discoverable without a DB join.
      labels: %{
        "fluxvale.io/gateway" => gateway.id,
        "fluxvale.io/access-domain" => domain.id
      }
    }

    base
    |> put_access_service(mode)
    |> put_access_tls_secret(tls_secret)
  end

  # Serving dials the app (beacon attached); wake dials the platform via
  # the same ExternalName `wake` Service the public wake mode uses — and
  # the beacon is NOT attached there (nothing is being forwarded).
  defp access_middlewares(:serving), do: [@beacon_middleware]
  defp access_middlewares(:wake), do: [@access_wake_middleware]

  defp put_access_service(spec, :serving),
    do: Map.merge(spec, %{service_name: "app", service_port: 80})

  defp put_access_service(spec, :wake),
    do: Map.merge(spec, %{service_name: @wake_service, service_port: beacon_config()[:port]})

  defp put_access_tls_secret(spec, nil), do: spec
  defp put_access_tls_secret(spec, secret), do: Map.put(spec, :tls_secret_name, secret)

  # Platform domain: the fleet wildcard (#116) rides the default
  # TLSStore — `tls: true` alone, NO secretName. Custom: the domain's
  # cert is REPLICAATED into this namespace first (Traefik's CRD
  # provider reads tls.secretName only in the route's namespace — a
  # bare cross-namespace ref can never serve), and only from a
  # :verified row with a ref recorded. An unverified domain must never
  # route, and a source Secret that is missing or unreadable is a dead
  # cert — either way the row's hostnames are skipped (logged: dark is
  # the posture, not a fault).
  defp access_tls_secret(_kubeconfig, %{kind: :platform}, _instance), do: {:ok, nil}

  defp access_tls_secret(
         kubeconfig,
         %{kind: :custom, state: :verified, cert_secret_ref: ref} = domain,
         instance
       )
       when is_binary(ref) do
    case ensure_access_cert_secret(kubeconfig, domain, instance.namespace) do
      {:ok, local_name} ->
        {:ok, local_name}

      {:error, reason} ->
        Logger.warning(
          "Access edge: skipping hostnames under custom domain #{domain.domain} — its " <>
            "certificate secret could not be replicated (#{inspect(reason)}); never " <>
            "routing a dead cert"
        )

        :skip
    end
  end

  defp access_tls_secret(_kubeconfig, %{kind: :custom, state: state, domain: domain}, _instance) do
    Logger.warning(
      "Access edge: skipping hostnames under custom domain #{domain} — not servable " <>
        "(state: #{inspect(state)}, no certificate secret recorded)"
    )

    :skip
  end

  @doc """
  The instance-namespace REPLICA of a custom domain's issued-wildcard
  Secret (ADR-0040 Am. 1 as built): reads the source Secret cert-manager
  wrote in the certificate namespace (`:access_domains,
  :certificate_namespace` + the row's `cert_secret_ref`) and SSA-copies
  `tls.crt`/`tls.key` into `namespace` as
  `access-domain-cert-<short-random-tail>` — Traefik's CRD provider
  resolves `tls.secretName` ONLY in the IngressRoute's own namespace, so
  the access routes reference this LOCAL name. Labels carry the domain
  id (a replica is discoverable as the domain it serves). SSA — a
  renewal rotation converges on re-apply. `{:ok, local_name}` or
  `{:error, reason}` (the caller never routes on a failed replication).
  """
  @spec ensure_access_cert_secret(Kubereq.Kubeconfig.t(), AccessDomain.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_access_cert_secret(kubeconfig, domain, namespace) do
    with {:ok, data} <- source_cert_data(kubeconfig, domain),
         {:ok, _secret} <-
           Secret.create(kubeconfig, namespace, local_cert_name(domain), data, %{
             "fluxvale.io/access-domain" => domain.id
           }) do
      {:ok, local_cert_name(domain)}
    end
  end

  defp source_cert_data(kubeconfig, domain) do
    namespace = certificate_namespace()

    case Secret.get_data(kubeconfig, namespace, domain.cert_secret_ref) do
      {:ok, %{"tls.crt" => crt, "tls.key" => key}}
      when is_binary(crt) and is_binary(key) and crt != "" and key != "" ->
        {:ok, %{"tls.crt" => crt, "tls.key" => key}}

      {:ok, _malformed} ->
        {:error, :cert_secret_malformed}

      {:error, _reason} = error ->
        error
    end
  end

  # The replica's name: the object_name short_id discipline (the RANDOM
  # TAIL of the domain id, never the uuid head — the AccessDomain
  # certificate_name rule).
  defp local_cert_name(domain) do
    short_id =
      domain.id
      |> to_string()
      |> String.replace("-", "")
      |> String.slice(-10, 10)

    "access-domain-cert-#{short_id}"
  end

  defp certificate_namespace do
    config = Application.fetch_env!(:flux_vale, :access_domains)
    Keyword.fetch!(config, :certificate_namespace)
  end

  # The object_name short_id discipline (AccessDomain.certificate_name,
  # the provider's object_name): the RANDOM TAIL of the row id, never
  # the uuid head — a uuid v7's leading hex is a millisecond timestamp,
  # identical for every row minted in the same window, so the head would
  # collide two instances' routes.
  defp access_route_name(hostname) do
    short_id =
      hostname.id
      |> to_string()
      |> String.replace("-", "")
      |> String.slice(-10, 10)

    "access-#{short_id}"
  end

  defp delete_access_routes(kubeconfig, instance) do
    instance.id
    |> hostname_rows()
    |> Enum.reduce_while(:ok, fn hostname, :ok ->
      case safe_delete_route(kubeconfig, instance.namespace, access_route_name(hostname)) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  # 404 is the posture already holding — the access none is idempotent
  # (the safe_delete stance above).
  defp safe_delete_middleware(kubeconfig, namespace, name) do
    case Middleware.delete(kubeconfig, namespace, name) do
      :ok -> :ok
      {:error, %Error{reason: :not_found}} -> :ok
      {:error, _error} = error -> error
    end
  end

  # The dispatched entries' public bodies — shared with apply_public/3
  # (the compensating-restore seam above).
  defp serving_apply(kubeconfig, instance) do
    namespace = instance.namespace
    domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    with {:ok, _beacon} <-
           Middleware.create(kubeconfig, namespace, @beacon_middleware, beacon_spec(instance)),
         {:ok, _app} <-
           Ingress.create(kubeconfig, namespace, @app_ingress, serving_spec(instance, domain)) do
      maybe_apply_dav(kubeconfig, instance, domain, :serving)
    end
  end

  defp wake_apply(kubeconfig, instance) do
    namespace = instance.namespace
    domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    with :ok <- ensure_wake_targets(kubeconfig, instance),
         {:ok, _app} <-
           Ingress.create(kubeconfig, namespace, @app_ingress, wake_spec(instance, domain)) do
      maybe_apply_dav(kubeconfig, instance, domain, :wake)
    end
  end

  @doc """
  The wake targets, dormant: the `wake` ExternalName Service and the
  wake-marker Middleware, applied at DEPLOY so the first sleep's only
  cluster-visible change is the route rewrite. Traefik learns objects
  by watch — a first sleep that mints all three at once leaves a
  window where the rewritten route references objects Traefik hasn't
  observed yet (observed live: 502/504s for tens of seconds on a fresh
  instance's first sleep; pre-created targets close it).
  """
  @spec ensure_wake_targets(Kubereq.Kubeconfig.t(), Instance.t()) :: :ok | {:error, term()}
  def ensure_wake_targets(kubeconfig, instance) do
    namespace = instance.namespace

    with {:ok, _service} <-
           Service.create(kubeconfig, namespace, @wake_service, wake_service_spec()),
         {:ok, _marker} <-
           Middleware.create(kubeconfig, namespace, @wake_middleware, wake_marker_spec(instance)) do
      :ok
    end
  end

  # The beacon (the issue's "middleware writing per-instance last-used
  # markers"): Traefik consults the platform before forwarding; the
  # instance rides the address. authRequestHeaders is a LIMITER, not
  # an enabler — Traefik forwards every request header when the list
  # is empty, and the beacon has no business seeing cookies or
  # authorization headers; the User-Agent rides it because probes are
  # filtered by name.
  defp beacon_spec(instance) do
    %{
      forward_auth: %{
        address: beacon_address(instance),
        auth_request_headers: ["User-Agent"]
      }
    }
  end

  defp wake_marker_spec(instance) do
    %{request_headers: %{@instance_header => instance.id}}
  end

  defp wake_service_spec do
    config = beacon_config()

    %{
      external_name: "#{config[:service]}.#{beacon_namespace()}.svc.cluster.local",
      port: config[:port]
    }
  end

  defp serving_spec(instance, domain) do
    %{
      subdomain: instance.slug,
      service_name: "app",
      service_port: 80,
      tls: true,
      domain: domain,
      middlewares: [@beacon_middleware]
    }
  end

  defp wake_spec(instance, domain) do
    %{
      subdomain: instance.slug,
      service_name: @wake_service,
      service_port: beacon_config()[:port],
      tls: true,
      domain: domain,
      middlewares: [@wake_middleware]
    }
  end

  defp dav_serving_spec(instance, domain) do
    path_prefix = Application.fetch_env!(:flux_vale, :file_access)[:path_prefix]
    base = serving_spec(instance, domain)

    Map.merge(base, %{service_name: "dav", path_prefix: path_prefix})
  end

  defp dav_wake_spec(instance, domain) do
    path_prefix = Application.fetch_env!(:flux_vale, :file_access)[:path_prefix]
    wake = wake_spec(instance, domain)

    Map.merge(wake, %{path_prefix: path_prefix})
  end

  # Same gate as DeployInstance's sidecar decision: no volume, no dav
  # route ever existed — wake-mode must not mint one.
  defp maybe_apply_dav(kubeconfig, instance, domain, mode) do
    if dav_routed?(instance) do
      spec = dav_spec(instance, domain, mode)

      case Ingress.create(kubeconfig, instance.namespace, @dav_ingress, spec) do
        {:ok, _ingress} -> :ok
        {:error, _error} = error -> error
      end
    else
      :ok
    end
  end

  # Same gate as DeployInstance's sidecar decision: no volume, no dav
  # route ever existed — private-mode must not hunt one.
  defp maybe_delete_dav(kubeconfig, instance) do
    if dav_routed?(instance) do
      safe_delete_route(kubeconfig, instance.namespace, @dav_ingress)
    else
      :ok
    end
  end

  # 404 is the posture already holding — the private apply is
  # idempotent (TeardownInstance's safe_delete stance).
  defp safe_delete_route(kubeconfig, namespace, name) do
    case Ingress.delete(kubeconfig, namespace, name) do
      :ok -> :ok
      {:error, %Error{reason: :not_found}} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp dav_routed?(%{file_access: true, storage_gb: gb}) when gb > 0, do: true
  defp dav_routed?(_instance), do: false

  defp dav_spec(instance, domain, :serving), do: dav_serving_spec(instance, domain)
  defp dav_spec(instance, domain, :wake), do: dav_wake_spec(instance, domain)

  defp beacon_address(instance) do
    config = beacon_config()

    "http://#{config[:service]}.#{beacon_namespace()}.svc.cluster.local:#{config[:port]}" <>
      "/internal/edge/touch?instance=#{instance.id}"
  end

  # The platform's own namespace is the RBAC SA's namespace — one
  # config source (INSTANCE_RBAC_SA_NAMESPACE overrides both at once).
  defp beacon_namespace do
    Application.fetch_env!(:flux_vale, :instance_rbac)[:service_account_namespace]
  end

  defp beacon_config do
    Application.fetch_env!(:flux_vale, :edge_beacon)
  end
end
