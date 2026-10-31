defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfig do
  @moduledoc """
  Builds the `tailscale serve` config for a gateway (ADR-0039 §3) — the
  routing table, as pure data.

  Shape (verified against `ipn.ServeConfig` and `tailscale serve status
  --json`, spike E2.3):

      %{"TCP" => %{"8443" => %{"HTTPS" => true}},
        "Web" => %{"<hostname>.<tailnet-domain>:8443" => %{"Handlers" => %{"/" => %{"Proxy" => url}}}},
        "AllowFunnel" => %{}}

  One node, one MagicDNS name, **per-app ports at root path** — the B1
  decision. Serve has no hostname dimension (a request with another Host
  header is a 404, E2.1), so a second app cannot be a second name on one
  node; a second *port* is the mechanism.

  The `Web` key is the CONCRETE FQDN (`fv-xxxxxxxx` — ours — joined to
  the tailnet's MagicDNS suffix — the owner's, carried on the row).
  The first cut wrote the literal `"<hostname>.${TS_CERT_DOMAIN}"` on
  the theory that `containerboot` substitutes it; on the pinned image
  (v1.90.6, `cmd/containerboot/serve.go`) that substitution runs only
  when the node can issue certs, substitutes `CertDomains[0]` — the
  SUFFIX, not this node's FQDN — and silently declines to apply the
  config at all when the tailnet has no cert domain (`ValueNoHTTPS`).
  The live staging gateway never served a request because of it. A
  concrete key is what the daemon would apply verbatim, and what the
  Secret shows: no hidden expansion step between what we write and what
  serves.

  `AllowFunnel %{}` is deliberate and load-bearing: an empty map is
  "nothing is funneled", so a config that somehow carried a Funnel entry
  would not be produced here at all. Private access must never become
  public access.

  **The tunnel limb (ADR-0040 §1):** when app config `:flux_vale,
  :access_edge` is set, the TCP arm gains raw forwards — `"443"` (and
  `"80"` for redirects) → the access edge, uninterpreted (TLS included:
  Traefik terminates, routes by hostname). The limb is config-gated so
  local stacks — no access edge — produce a config byte-identical to
  the pre-ADR shape (pinned by test — S2's byte-identical lesson). The
  per-app `Web` entries are untouched in both states: the ts.net port
  address remains the fallback that works with nothing claimed.
  """

  @doc """
  The whole config for a gateway: `entries` is `[{port, target_url}]`.

  An empty entry list produces a config with no `Web`/`TCP` arms — a
  valid "nothing served yet" config (the owner opted in but attached no
  instance); the domain is unused there, so a gateway provisioned
  before its domain is known still gets its empty config.
  """
  @spec build(String.t(), String.t() | nil, [{String.t(), String.t()}]) :: map()
  def build(hostname, tailnet_domain, entries) do
    per_app = tcp_arm(entries)
    tunnel = tunnel_arm()
    tcp = Map.merge(per_app, tunnel)

    %{
      "TCP" => tcp,
      "Web" => web_arm(hostname, tailnet_domain, entries),
      "AllowFunnel" => %{}
    }
  end

  @doc """
  Encodes the config for the mounted Secret. `containerboot` watches the
  file and re-applies on change.
  """
  @spec encode(map()) :: String.t()
  def encode(config), do: Jason.encode!(config)

  # Only HTTPS ports. A private-access gateway has no business serving
  # plaintext to the tailnet (the tailnet is already encrypted, but the
  # cert is what makes the app's absolute-URL generation work).
  defp tcp_arm(entries) do
    Map.new(entries, fn {port, _target} -> {port, %{"HTTPS" => true}} end)
  end

  # The strong form's raw forwards (ADR-0040 §1): the gateway tunnels
  # uninterpreted bytes to the access edge, where Traefik routes by
  # Host and terminates TLS from the platform's cert Secrets. The
  # per-app ports never collide with these: the pool starts at 8443
  # (`Ports`), deliberately above serve's common 443/80.
  defp tunnel_arm do
    case Application.get_env(:flux_vale, :access_edge) do
      config when is_list(config) ->
        service = Keyword.fetch!(config, :service)
        https_port = Keyword.fetch!(config, :https_port)
        http_port = Keyword.fetch!(config, :http_port)

        %{
          "443" => %{"TCPForward" => "#{service}:#{https_port}"},
          "80" => %{"TCPForward" => "#{service}:#{http_port}"}
        }

      # Local stacks have no access edge: the limb is OMITTED and the
      # config is byte-identical to the pre-ADR shape (pinned by test).
      _unset ->
        %{}
    end
  end

  defp web_arm(_hostname, _tailnet_domain, []), do: %{}

  # A nil domain with entries would mint `"fv-….:8443"` — a key no
  # daemon can match. The provider guards this before calling; the
  # guard here keeps the pure function from silently building garbage
  # for any future caller.
  defp web_arm(hostname, tailnet_domain, entries) when is_binary(tailnet_domain) do
    Map.new(entries, fn {port, target} ->
      {"#{hostname}.#{tailnet_domain}:#{port}", %{"Handlers" => %{"/" => %{"Proxy" => target}}}}
    end)
  end

  @doc """
  The asleep target: the platform's in-cluster access endpoint (ADR-0039
  §6). Serve appends the visitor's path to the target's path, so a deep
  link survives the wake.

  The platform's own service coordinates come from `:edge_beacon` — one
  source for "where the platform is in-cluster" (the wake route's own
  config), not a second hard-coded name.
  """
  @spec asleep_target(Ash.UUID.t(), Ash.UUID.t()) :: String.t()
  def asleep_target(gateway_id, instance_id) do
    config = Application.fetch_env!(:flux_vale, :edge_beacon)
    namespace = platform_namespace()

    "http://#{config[:service]}.#{namespace}.svc.cluster.local:#{config[:port]}" <>
      "/internal/access/#{gateway_id}/#{instance_id}"
  end

  @doc """
  The awake target: the instance's own Service, by namespace-qualified
  DNS (`app.<namespace>.svc.cluster.local`) so the gateway needs no
  cross-namespace Service alias. Port 80 is the instance Service's port
  (the deployer's convention).
  """
  @spec awake_target(String.t()) :: String.t()
  def awake_target(namespace) do
    "http://app.#{namespace}.svc.cluster.local:80"
  end

  @doc """
  The target for an instance's current status: asleep (`:sleeping`) goes
  to the platform so the next request wakes it; everything else goes
  straight at the app. `:stopped`/`:error`/`:deploying` target the app
  too — serve answers 502, which is honest (nothing to wake: the owner
  stopped it, or the deploy is still landing).

  The wake target is gated on `:access_gateway, :wake_intercept_enabled`
  (on since #273). The flag gates NEW serve-config writes only — a row
  that is already `:sleeping` keeps its platform target until its next
  wake->sleep cycle (or a re-paste / detach-attach refresh); setting it
  false never unmounts the route, and no writer converges a
  still-pointed-at-the-app sleeping row (the sweep selects `:running`
  only).
  """
  @spec target_for(Ash.UUID.t(), map()) :: String.t()
  def target_for(gateway_id, %{status: :sleeping} = instance) do
    if wake_intercept_enabled?() do
      asleep_target(gateway_id, instance.id)
    else
      awake_target(instance.namespace)
    end
  end

  def target_for(_gateway_id, instance), do: awake_target(instance.namespace)

  defp wake_intercept_enabled? do
    Application.get_env(:flux_vale, :access_gateway, [])[:wake_intercept_enabled] == true
  end

  defp platform_namespace do
    Application.fetch_env!(:flux_vale, :instance_rbac)[:service_account_namespace]
  end
end
