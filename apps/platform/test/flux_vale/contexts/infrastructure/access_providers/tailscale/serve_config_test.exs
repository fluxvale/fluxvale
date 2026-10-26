defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfigTest do
  @moduledoc false

  # ADR-0039 §3's routing table, as pure data — the shape is pinned
  # against `ipn.ServeConfig` and `tailscale serve status --json` (spike
  # E2.3): TCP ports, Web keyed "<name>:<port>", handlers keyed "/".
  #
  # The config is a Secret the platform writes, so these assertions are
  # the contract `containerboot` applies — a wrong key here is a gateway
  # that serves nothing.

  use ExUnit.Case, async: true

  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfig

  @hostname "fv-1a2b3c4d"

  describe "build/2" do
    test "one app at root on its own port" do
      config =
        ServeConfig.build(@hostname, [{"8443", "http://app.fluxvale-app-x.svc.cluster.local:80"}])

      assert config["TCP"] == %{"8443" => %{"HTTPS" => true}}

      # ${TS_CERT_DOMAIN} — the platform does not know the owner's
      # tailnet suffix; containerboot substitutes it (§3).
      assert config["Web"] == %{
               "#{@hostname}.${TS_CERT_DOMAIN}:8443" => %{
                 "Handlers" => %{
                   "/" => %{"Proxy" => "http://app.fluxvale-app-x.svc.cluster.local:80"}
                 }
               }
             }
    end

    test "two apps get two ports, each at root — the B1 compromise" do
      config =
        ServeConfig.build(@hostname, [
          {"8443", "http://app.ns-a.svc.cluster.local:80"},
          {"8444", "http://app.ns-b.svc.cluster.local:80"}
        ])

      tcp_keys = Map.keys(config["TCP"])
      web_keys = Map.keys(config["Web"])
      tcp = Enum.sort(tcp_keys)
      web = Enum.sort(web_keys)

      assert tcp == ["8443", "8444"]

      assert web == [
               "#{@hostname}.${TS_CERT_DOMAIN}:8443",
               "#{@hostname}.${TS_CERT_DOMAIN}:8444"
             ]

      # Every handler is "/" — root path per app, never a path mount
      # (apps that emit absolute URLs break under path prefixes).
      for {_key, web} <- config["Web"] do
        assert Map.keys(web["Handlers"]) == ["/"]
      end
    end

    test "an empty gateway serves nothing yet — valid, not broken" do
      config = ServeConfig.build(@hostname, [])

      assert config["TCP"] == %{}
      assert config["Web"] == %{}
    end

    test "funnel is explicitly empty — private access never becomes public" do
      config = ServeConfig.build(@hostname, [{"8443", "http://app.ns.svc.cluster.local:80"}])

      assert config["AllowFunnel"] == %{}
    end

    test "the encoded config is valid JSON with the keys the daemon reads" do
      config =
        ServeConfig.build(@hostname, [{"8443", "http://app.ns.svc.cluster.local:80"}])

      encoded = ServeConfig.encode(config)
      decoded = Jason.decode!(encoded)

      assert decoded["TCP"]["8443"]["HTTPS"] == true
      assert decoded["Web"]["#{@hostname}.${TS_CERT_DOMAIN}:8443"]["Handlers"]["/"]["Proxy"]
    end
  end

  describe "target_for/2" do
    test "a sleeping instance targets the platform's access endpoint" do
      gateway_id = "0192f000-0000-7000-8000-000000000001"
      instance = %{id: "0192f000-0000-7000-8000-000000000002", status: :sleeping, namespace: "ns"}

      target = ServeConfig.target_for(gateway_id, instance)

      # The wake endpoint, addressed by the pairing — ADR-0039 §6.
      assert target =~ "/internal/access/#{gateway_id}/#{instance.id}"
      assert target =~ "svc.cluster.local"
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
