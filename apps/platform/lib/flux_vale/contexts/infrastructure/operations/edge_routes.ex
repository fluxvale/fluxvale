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

  Deploys land serving; `SleepInstance` flips both routes to wake; the
  first request after `:running` flips them back (the wake endpoint's
  restore — the visitor's reload lands on the app). All applies are
  SSA-idempotent, so every mode-apply re-applies its full object set
  (routes + middlewares + the wake Service): instances deployed before
  #203 converge on their first sleep or restore.

  Consumed by DeployInstance (initial serving set), SleepInstance
  (wake flip), and the wake endpoint (restore flip) — the specs are the
  shared boundary, so they live here rather than being copied three
  ways (the operations-own-their-constants rule's sanctioned exception:
  this IS the one owner).
  """

  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.Instance

  @app_ingress "app-ingress"
  @dav_ingress "app-dav"
  @beacon_middleware "fluxvale-activity"
  @wake_middleware "fluxvale-wake"
  @wake_service "wake"
  # The wake marker: names the instance for the wake endpoint. Custom
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
  """
  @spec apply_serving(Kubereq.Kubeconfig.t(), Instance.t()) ::
          :ok | {:error, term()}
  def apply_serving(kubeconfig, instance) do
    namespace = instance.namespace
    domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    with {:ok, _beacon} <-
           Middleware.create(kubeconfig, namespace, @beacon_middleware, beacon_spec(instance)),
         {:ok, _app} <-
           Ingress.create(kubeconfig, namespace, @app_ingress, serving_spec(instance, domain)) do
      maybe_apply_dav(kubeconfig, instance, domain, :serving)
    end
  end

  @doc """
  Applies the wake-mode object set: the dormant wake targets (see
  `ensure_wake_targets/2`) plus the wake-mode app route (+ `/dav`).
  Called from the sleep path — the app Deployment is already at 0 by
  then, so visitors must land on the wake endpoint, not a
  connectionless Service.
  """
  @spec apply_wake(Kubereq.Kubeconfig.t(), Instance.t()) :: :ok | {:error, term()}
  def apply_wake(kubeconfig, instance) do
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
