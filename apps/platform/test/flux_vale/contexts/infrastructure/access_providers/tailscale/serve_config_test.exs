defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfigTest do
  @moduledoc false

  # ADR-0039 §3's routing table, as pure data — the shape is pinned
  # against `ipn.ServeConfig` and `tailscale serve status --json` (spike
  # E2.3): TCP ports, Web keyed "<name>:<port>", handlers keyed "/".
  #
  # The config is a Secret the platform writes, so these assertions are
  # the contract `containerboot` applies — a wrong key here is a gateway
  # that serves nothing.

  use ExUnit.Case, async: false

  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfig

  @hostname "fv-1a2b3c4d"

  # async: false (see disable_wake_intercept/0): the flag tests mutate
  # node-global application env.

  defp enable_wake_intercept do
    previous = Application.get_env(:flux_vale, :access_gateway)

    Application.put_env(
      :flux_vale,
      :access_gateway,
      Keyword.put(previous, :wake_intercept_enabled, true)
    )

    on_exit(fn -> Application.put_env(:flux_vale, :access_gateway, previous) end)
  end

  # The flag-off posture test flips the SHIPPED default (on since #273),
  # so this module must run exclusively — the env is node-global and
  # other suites' config generation reads it.
  defp disable_wake_intercept do
    previous = Application.get_env(:flux_vale, :access_gateway)

    Application.put_env(
      :flux_vale,
      :access_gateway,
      Keyword.put(previous, :wake_intercept_enabled, false)
    )

    on_exit(fn -> Application.put_env(:flux_vale, :access_gateway, previous) end)
  end

  describe "build/3" do
    @domain "example.ts.net"

    test "one app at root on its own port, under the CONCRETE tailnet FQDN" do
      # The tunnel limb is its own concern (the describe below); the
      # no-edge state is a deliberate Application-env deletion now —
      # the boot default is the fleet edge (infra #119).
      clear_access_edge()

      config =
        ServeConfig.build(@hostname, @domain, [
          {"8443", "http://app.fluxvale-app-x.svc.cluster.local:80"}
        ])

      assert config["TCP"] == %{"8443" => %{"HTTPS" => true}}

      # The concrete FQDN — the P1 fix. The first cut wrote the literal
      # "<hostname>.${TS_CERT_DOMAIN}" on the theory that containerboot
      # expands it; on the pinned image (v1.90.6) the expansion either
      # substitutes only the suffix or declines to apply the config
      # outright, and the gateway served nothing. What we write is what
      # the daemon applies — verbatim.
      assert config["Web"] == %{
               "#{@hostname}.#{@domain}:8443" => %{
                 "Handlers" => %{
                   "/" => %{"Proxy" => "http://app.fluxvale-app-x.svc.cluster.local:80"}
                 }
               }
             }
    end

    test "the encoded config carries no unexpanded placeholder anywhere" do
      config =
        ServeConfig.build(@hostname, @domain, [
          {"8443", "http://app.ns.svc.cluster.local:80"},
          {"8444", "http://app.ns-b.svc.cluster.local:80"}
        ])

      encoded = ServeConfig.encode(config)

      # The P1 regression pin: the running config is built from this
      # string with no expansion step between us and the daemon, so an
      # unexpanded `${...}` here is the live gateway's broken handshake.
      refute encoded =~ "${"
      refute encoded =~ "TS_CERT_DOMAIN"
    end

    test "two apps get two ports, each at root — the B1 compromise" do
      # The tunnel limb is its own concern (the describe below); the
      # no-edge state is a deliberate Application-env deletion now —
      # the boot default is the fleet edge (infra #119).
      clear_access_edge()

      config =
        ServeConfig.build(@hostname, @domain, [
          {"8443", "http://app.ns-a.svc.cluster.local:80"},
          {"8444", "http://app.ns-b.svc.cluster.local:80"}
        ])

      tcp_keys = Map.keys(config["TCP"])
      web_keys = Map.keys(config["Web"])
      tcp = Enum.sort(tcp_keys)
      web = Enum.sort(web_keys)

      assert tcp == ["8443", "8444"]

      assert web == [
               "#{@hostname}.#{@domain}:8443",
               "#{@hostname}.#{@domain}:8444"
             ]

      # Every handler is "/" — root path per app, never a path mount
      # (apps that emit absolute URLs break under path prefixes).
      for {_key, web} <- config["Web"] do
        assert Map.keys(web["Handlers"]) == ["/"]
      end
    end

    test "an empty gateway serves nothing yet — valid, not broken" do
      # The tunnel limb is its own concern (the describe below); the
      # no-edge state is a deliberate Application-env deletion now —
      # the boot default is the fleet edge (infra #119).
      clear_access_edge()

      config = ServeConfig.build(@hostname, @domain, [])

      assert config["TCP"] == %{}
      assert config["Web"] == %{}
    end

    # The backfill window: a pre-column row provisions and re-provisions
    # through the empty config (nothing attached, nothing to key on the
    # domain); the provider refuses the non-empty case separately.
    test "an empty config builds without a domain — the nothing-served-yet row" do
      # The tunnel limb is its own concern (the describe below); the
      # no-edge state is a deliberate Application-env deletion now —
      # the boot default is the fleet edge (infra #119).
      clear_access_edge()

      config = ServeConfig.build(@hostname, nil, [])

      assert config["TCP"] == %{}
      assert config["Web"] == %{}
    end

    test "a nil domain with entries is refused — no key a daemon can't match" do
      # The laundered nil (a bare nil literal would trip warnings-as-
      # errors): the migration-window row's shape must not silently
      # mint "fv-….:8443" for any future caller.
      nil_domain = Enum.at([nil], 0)

      assert_raise FunctionClauseError, fn ->
        ServeConfig.build(@hostname, nil_domain, [
          {"8443", "http://app.ns.svc.cluster.local:80"}
        ])
      end
    end

    test "funnel is explicitly empty — private access never becomes public" do
      config =
        ServeConfig.build(@hostname, @domain, [{"8443", "http://app.ns.svc.cluster.local:80"}])

      assert config["AllowFunnel"] == %{}
    end

    test "the encoded config is valid JSON with the keys the daemon reads" do
      config =
        ServeConfig.build(@hostname, @domain, [{"8443", "http://app.ns.svc.cluster.local:80"}])

      encoded = ServeConfig.encode(config)
      decoded = Jason.decode!(encoded)

      assert decoded["TCP"]["8443"]["HTTPS"] == true
      assert decoded["Web"]["#{@hostname}.#{@domain}:8443"]["Handlers"]["/"]["Proxy"]
    end
  end

  # ------------------------------------------------------------------
  # The tunnel limb (ADR-0040 §1): raw 443/80 → the access edge,
  # config-gated. Local stacks (no :access_edge) must produce a config
  # byte-identical to the pre-ADR shape — the S2 lesson, pinned here.
  # ------------------------------------------------------------------

  describe "build/3 — the tunnel limb" do
    # async: false (see disable_wake_intercept/0): the config tests
    # mutate node-global application env.

    defp set_access_edge do
      previous = Application.get_env(:flux_vale, :access_edge)

      Application.put_env(:flux_vale, :access_edge,
        service: "traefik.traefik.svc.cluster.local",
        https_port: 443,
        http_port: 80
      )

      on_exit(fn -> Application.put_env(:flux_vale, :access_edge, previous) end)
    end

    defp clear_access_edge do
      previous = Application.get_env(:flux_vale, :access_edge)
      Application.delete_env(:flux_vale, :access_edge)

      on_exit(fn -> Application.put_env(:flux_vale, :access_edge, previous) end)
    end

    test "with an access edge the TCP arm gains the raw 443/80 forwards" do
      set_access_edge()

      config =
        ServeConfig.build(@hostname, @domain, [
          {"8443", "http://app.ns.svc.cluster.local:80"}
        ])

      assert config["TCP"]["443"] == %{
               "TCPForward" => "traefik.traefik.svc.cluster.local:443"
             }

      assert config["TCP"]["80"] == %{"TCPForward" => "traefik.traefik.svc.cluster.local:80"}

      # The per-app HTTPS entry rides beside the forwards, untouched.
      assert config["TCP"]["8443"] == %{"HTTPS" => true}

      # The Web arm never gains a tunnel entry — the forwards are
      # hostname-agnostic; Traefik routes by Host past the tunnel.
      refute Map.has_key?(config["Web"], "443")
      refute Map.has_key?(config["Web"], "80")
    end

    test "the runtime default parses to the fleet's access edge (infra #119)" do
      # runtime.exs runs at boot: with ACCESS_EDGE_SERVICE unset it
      # defaults the config to the fleet entrypoint (env override wins,
      # so CI never sets it). This pins the parsed DEFAULT the release
      # and the local Tilt stack boot with — the rider of ADR-0040 S4.
      config = Application.get_env(:flux_vale, :access_edge)

      assert config[:service] == "traefik.traefik.svc.cluster.local"
      assert config[:https_port] == 8444
      assert config[:http_port] == 8080

      # And it DRIVES the tunnel arm end to end — the address is read
      # from config everywhere, never hardcoded.
      built =
        ServeConfig.build(@hostname, @domain, [
          {"8443", "http://app.ns.svc.cluster.local:80"}
        ])

      assert built["TCP"]["443"] == %{
               "TCPForward" => "traefik.traefik.svc.cluster.local:8444"
             }

      assert built["TCP"]["80"] == %{"TCPForward" => "traefik.traefik.svc.cluster.local:8080"}
    end

    test "without an access edge the config is BYTE-IDENTICAL to the pre-ADR shape" do
      clear_access_edge()

      config =
        ServeConfig.build(@hostname, @domain, [
          {"8443", "http://app.ns.svc.cluster.local:80"}
        ])

      # Exact-shape equality: this map is what ADR-0039 shipped, so a
      # stray tunnel key (or a reshaped arm) fails here before a fleet
      # of gateways mounts a changed routing table.
      assert config == %{
               "TCP" => %{"8443" => %{"HTTPS" => true}},
               "Web" => %{
                 "#{@hostname}.#{@domain}:8443" => %{
                   "Handlers" => %{
                     "/" => %{"Proxy" => "http://app.ns.svc.cluster.local:80"}
                   }
                 }
               },
               "AllowFunnel" => %{}
             }

      # The empty config too — the provision-time posture.
      assert ServeConfig.build(@hostname, @domain, []) == %{
               "TCP" => %{},
               "Web" => %{},
               "AllowFunnel" => %{}
             }
    end
  end

  describe "target_for/2" do
    test "a sleeping instance targets the platform's access endpoint" do
      gateway_id = "0192f000-0000-7000-8000-000000000001"
      instance = %{id: "0192f000-0000-7000-8000-000000000002", status: :sleeping, namespace: "ns"}

      # Explicit on (the shipped default since #273): the sleeping
      # target is the wake endpoint the intercept controller serves.
      enable_wake_intercept()

      target = ServeConfig.target_for(gateway_id, instance)

      # The wake endpoint, addressed by the pairing — ADR-0039 §6.
      assert target =~ "/internal/access/#{gateway_id}/#{instance.id}"
      assert target =~ "svc.cluster.local"
    end

    test "with the intercept disabled a sleeping instance targets the app itself" do
      instance = %{id: "i", status: :sleeping, namespace: "fluxvale-app-abc"}

      # The flag-off posture (#273): with the intercept stood down, a
      # sleeping instance points at its own Service — serve answers an
      # honest 502 rather than routing at a dead endpoint. Explicit,
      # because the shipped default is on.
      disable_wake_intercept()

      assert ServeConfig.target_for("g", instance) ==
               "http://app.fluxvale-app-abc.svc.cluster.local:80"
    end

    test "a running instance targets the app's own Service" do
      instance = %{id: "x", status: :running, namespace: "fluxvale-app-abc"}

      assert ServeConfig.target_for("gw", instance) ==
               "http://app.fluxvale-app-abc.svc.cluster.local:80"
    end

    # :stopped/:error/:deploying are honest 502s at the app — nothing to
    # wake (the owner stopped it, or the deploy is landing).
    test "any non-sleeping status targets the app, not the wake endpoint" do
      for status <- [:stopped, :error, :deploying, :starting, :restoring] do
        instance = %{id: "x", status: status, namespace: "ns"}

        assert ServeConfig.target_for("gw", instance) == "http://app.ns.svc.cluster.local:80"
      end
    end
  end
end
