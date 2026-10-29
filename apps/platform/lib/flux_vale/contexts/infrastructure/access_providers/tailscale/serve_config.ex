defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfig do
  @moduledoc """
  Builds the `tailscale serve` config for a gateway (ADR-0039 §3) — the
  routing table, as pure data.

  Shape (verified against `ipn.ServeConfig` and `tailscale serve status
  --json`, spike E2.3):

      %{"TCP" => %{"8443" => %{"HTTPS" => true}},
        "Web" => %{"<hostname>.${TS_CERT_DOMAIN}" => %{"Handlers" => %{"/" => %{"Proxy" => url}}}},
        "AllowFunnel" => %{}}

  One node, one MagicDNS name, **per-app ports at root path** — the B1
  decision. Serve has no hostname dimension (a request with another Host
  header is a 404, E2.1), so a second app cannot be a second name on one
  node; a second *port* is the mechanism.

  The `Web` key carries `${TS_CERT_DOMAIN}` rather than a concrete
  `.ts.net` name: the platform does not know the tailnet's MagicDNS
  suffix (it is the owner's), and `containerboot` substitutes the real
  FQDN. The hostname prefix (`fv-xxxxxxxx`) is ours and stays.

  `AllowFunnel %{}` is deliberate and load-bearing: an empty map is
  "nothing is funneled", so a config that somehow carried a Funnel entry
  would not be produced here at all. Private access must never become
  public access.
  """

  @doc """
  The whole config for a gateway: `entries` is `[{port, target_url}]`.

  An empty entry list produces a config with no `Web`/`TCP` arms — a
  valid "nothing served yet" config (the owner opted in but attached no
  instance). `containerboot` applies it harmlessly.
  """
  @spec build(String.t(), [{String.t(), String.t()}]) :: map()
  def build(hostname, entries) do
    %{
      "TCP" => tcp_arm(entries),
      "Web" => web_arm(hostname, entries),
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

  defp web_arm(_hostname, []), do: %{}

  defp web_arm(hostname, entries) do
    Map.new(entries, fn {port, target} ->
      {"#{hostname}.${TS_CERT_DOMAIN}:#{port}", %{"Handlers" => %{"/" => %{"Proxy" => target}}}}
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
  (on since #273): setting it false walks back to serve's honest 502 for
  sleeping instances — the flag-off posture if the intercept ever needs
  to be stood down.
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
