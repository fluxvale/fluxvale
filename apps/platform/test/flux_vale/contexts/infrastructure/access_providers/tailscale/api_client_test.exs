defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClientTest do
  @moduledoc """
  The Tailscale API client's wire contract (ADR-0040 §3, spike-pinned
  against the official SDK v2.12.0): bearer auth, the device match on
  the name's first label, the routes POST's replace semantics and the
  split-DNS PATCH's per-domain upsert (never a PUT). HTTP is
  Mimic-stubbed — the HitPay adapter's stance: the client translates
  wires into shapes, it does not talk to the API.
  """

  # async: false — the tests stub the global :tailscale_api app-env
  # block (capture and restore, the HitPay test's stance).
  use ExUnit.Case, async: false
  use Mimic

  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient

  @token "tskey-api-abc123"

  setup do
    original = Application.get_env(:flux_vale, :tailscale_api)

    Application.put_env(:flux_vale, :tailscale_api, base_url: "https://api.example")

    on_exit(fn -> Application.put_env(:flux_vale, :tailscale_api, original) end)

    :ok
  end

  # Every request rides the bearer header on the base URL from config —
  # the contract every function shares, pinned once here.
  defp expect_request(method, path, respond) do
    expect(Req, method, fn req, opts ->
      assert req.options[:base_url] == "https://api.example"
      assert Req.Request.get_header(req, "authorization") == ["Bearer #{@token}"]
      assert opts[:url] == path

      respond.(opts)
    end)
  end

  describe "devices_lookup/2" do
    test "the device's Tailscale IPs ride along (ADR-0040 §4's view answer)" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{
                 "id" => "777",
                 "name" => "fv-1a2b3c4d.example.ts.net",
                 "addresses" => ["100.64.0.1", "fd7a::1234"]
               }
             ]
           }
         }}
      end)

      assert {:ok, %{id: "777", tailscale_ips: ["100.64.0.1", "fd7a::1234"]}} =
               ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "a device without addresses is still found — with an empty IP list" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"devices" => [%{"id" => "5", "name" => "fv-1a2b3c4d.example.ts.net"}]}
         }}
      end)

      assert {:ok, %{id: "5", tailscale_ips: []}} =
               ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "finds the device whose name's FIRST label is the hostname" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{"id" => "999", "name" => "other-node.example.ts.net"},
               %{"id" => "777", "name" => "fv-1a2b3c4d.example.ts.net"}
             ]
           }
         }}
      end)

      assert {:ok, %{id: "777"}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    # A prefix is not a match — "fv-1a2b3c4d5e" must not satisfy
    # "fv-1a2b3c4d": the lookup is the claim's identity gate.
    test "matches the whole label, never a prefix" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"devices" => [%{"id" => "1", "name" => "fv-1a2b3c4d5e.example.ts.net"}]}
         }}
      end)

      assert {:error, :not_found} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "accepts the bare-array envelope" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: [%{"id" => "55", "name" => "fv-abcdef00.example.ts.net"}]
         }}
      end)

      assert {:ok, %{id: "55"}} = ApiClient.devices_lookup(@token, "fv-abcdef00")
    end

    # A device row without a usable name is skipped, not matched — the
    # lookup keeps scanning the rest of the tailnet's devices.
    test "a malformed device row is skipped, not matched" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{"id" => "66"},
               %{"id" => "88", "name" => "fv-1a2b3c4d.example.ts.net"}
             ]
           }
         }}
      end)

      assert {:ok, %{id: "88"}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "an unrecognized envelope or an absent node is :not_found" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok, %Req.Response{status: 200, body: %{"unexpected" => true}}}
      end)

      assert {:error, :not_found} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "401 is :unauthorized — the expired-or-revoked drift signal" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok, %Req.Response{status: 401, body: %{"error" => "expired"}}}
      end)

      assert {:error, :unauthorized} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "403 is :forbidden — a scope verdict, never folded into 401 (P2-7)" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok, %Req.Response{status: 403, body: %{"error" => "denied"}}}
      end)

      assert {:error, :forbidden} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "a scalar 2xx body is a bad payload, not an empty tailnet" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok, %Req.Response{status: 200, body: "gateway hiccup"}}
      end)

      assert {:error, {:bad_payload, 200}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "duplicate name matches pick the ONLINE one (P2-5)" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{"id" => "dead", "name" => "fv-1a2b3c4d.example.ts.net", "online" => false},
               %{"id" => "live", "name" => "fv-1a2b3c4d.example.ts.net", "online" => true}
             ]
           }
         }}
      end)

      assert {:ok, %{id: "live"}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "two online matches pick the freshest lastSeen (P2-5)" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{
                 "id" => "older",
                 "name" => "fv-1a2b3c4d.example.ts.net",
                 "online" => true,
                 "lastSeen" => "2026-10-01T00:00:00Z"
               },
               %{
                 "id" => "newest",
                 "name" => "fv-1a2b3c4d.example.ts.net",
                 "online" => true,
                 "lastSeen" => "2026-10-30T00:00:00Z"
               }
             ]
           }
         }}
      end)

      assert {:ok, %{id: "newest"}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "a single offline match is returned — it exists (P2-5)" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{"id" => "lone", "name" => "fv-1a2b3c4d.example.ts.net", "online" => false}
             ]
           }
         }}
      end)

      assert {:ok, %{id: "lone"}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "multiple offline matches are :node_ambiguous — never a claim against a ghost" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{"id" => "dead-1", "name" => "fv-1a2b3c4d.example.ts.net", "online" => false},
               %{"id" => "dead-2", "name" => "fv-1a2b3c4d.example.ts.net", "online" => false}
             ]
           }
         }}
      end)

      assert {:error, :node_ambiguous} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "a name-matched row without a usable id is refused, not claimed against" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"devices" => [%{"name" => "fv-1a2b3c4d.example.ts.net"}]}
         }}
      end)

      assert {:error, :not_found} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "an unparseable lastSeen loses to a parseable one (P2-5's tie-break is honest)" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{
                 "id" => "garbage-clock",
                 "name" => "fv-1a2b3c4d.example.ts.net",
                 "online" => true,
                 "lastSeen" => "not-a-timestamp"
               },
               %{
                 "id" => "honest",
                 "name" => "fv-1a2b3c4d.example.ts.net",
                 "online" => true,
                 "lastSeen" => "2026-10-30T00:00:00Z"
               }
             ]
           }
         }}
      end)

      assert {:ok, %{id: "honest"}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "two online matches with no lastSeen at all still resolve deterministically" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "devices" => [
               %{"id" => "first", "name" => "fv-1a2b3c4d.example.ts.net", "online" => true},
               %{"id" => "second", "name" => "fv-1a2b3c4d.example.ts.net", "online" => true}
             ]
           }
         }}
      end)

      # Both epoch-ranked: the FIRST maximal wins (Enum.max_by is
      # stable) — deterministic, never a raise.
      assert {:ok, %{id: "first"}} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end

    test "another non-2xx is a status+snippet error, body bounded" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:ok,
         %Req.Response{
           status: 500,
           body: %{"error" => String.duplicate("boom", 500)}
         }}
      end)

      assert {:error, %{status: 500, body: snippet}} = ApiClient.devices_lookup(@token, "fv")
      assert snippet =~ "boom"
      assert String.length(snippet) <= 200
    end

    test "a transport failure is :network_error" do
      expect_request(:get, "/api/v2/tailnet/-/devices", fn _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error} = ApiClient.devices_lookup(@token, "fv-1a2b3c4d")
    end
  end

  describe "routes_get/2" do
    test "returns advertised and enabled lists" do
      expect_request(:get, "/api/v2/device/777/routes", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"advertisedRoutes" => ["10.43.0.20/32"], "enabledRoutes" => ["10.0.0.1/32"]}
         }}
      end)

      assert {:ok, %{advertised: ["10.43.0.20/32"], enabled: ["10.0.0.1/32"]}} =
               ApiClient.routes_get(@token, "777")
    end

    test "missing keys are empty lists" do
      expect_request(:get, "/api/v2/device/777/routes", fn _opts ->
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      assert {:ok, %{advertised: [], enabled: []}} = ApiClient.routes_get(@token, "777")
    end

    test "401 maps to :unauthorized" do
      expect_request(:get, "/api/v2/device/777/routes", fn _opts ->
        {:ok, %Req.Response{status: 401, body: %{"error" => "expired"}}}
      end)

      assert {:error, :unauthorized} = ApiClient.routes_get(@token, "777")
    end

    test "a transport failure is :network_error" do
      expect_request(:get, "/api/v2/device/777/routes", fn _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :network_error} = ApiClient.routes_get(@token, "777")
    end

    test "a scalar 2xx body is a bad payload (the bracket access would crash the tick)" do
      expect_request(:get, "/api/v2/device/777/routes", fn _opts ->
        {:ok, %Req.Response{status: 200, body: []}}
      end)

      assert {:error, {:bad_payload, 200}} = ApiClient.routes_get(@token, "777")
    end
  end

  describe "routes_set/3" do
    test "POSTs the replacement enabled list" do
      expect_request(:post, "/api/v2/device/777/routes", fn opts ->
        assert opts[:json] == %{"routes" => ["10.43.0.20/32", "10.0.0.1/32"]}
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      assert :ok = ApiClient.routes_set(@token, "777", ["10.43.0.20/32", "10.0.0.1/32"])
    end

    test "non-2xx surfaces the status+snippet error" do
      expect_request(:post, "/api/v2/device/777/routes", fn _opts ->
        {:ok, %Req.Response{status: 400, body: %{"error" => "bad route"}}}
      end)

      assert {:error, %{status: 400, body: body}} =
               ApiClient.routes_set(@token, "777", [])

      assert body =~ "bad route"
    end
  end

  describe "split_dns_get/1" do
    test "returns the split-DNS map" do
      expect_request(:get, "/api/v2/tailnet/-/dns/split-dns", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"apps.customer.com" => ["10.43.0.20"], "corp.internal" => ["10.0.0.53"]}
         }}
      end)

      assert {:ok, %{"apps.customer.com" => ["10.43.0.20"]}} = ApiClient.split_dns_get(@token)
    end

    test "non-2xx surfaces the status+snippet error like every other read" do
      expect_request(:get, "/api/v2/tailnet/-/dns/split-dns", fn _opts ->
        {:ok, %Req.Response{status: 500, body: %{"error" => "dns oops"}}}
      end)

      assert {:error, %{status: 500, body: body}} = ApiClient.split_dns_get(@token)
      assert body =~ "dns oops"
    end

    test "a scalar 2xx body is a bad payload — Map.get could never survive it" do
      expect_request(:get, "/api/v2/tailnet/-/dns/split-dns", fn _opts ->
        {:ok, %Req.Response{status: 200, body: "not-a-map"}}
      end)

      assert {:error, {:bad_payload, 200}} = ApiClient.split_dns_get(@token)
    end

    test "a transport failure is :network_error" do
      expect_request(:get, "/api/v2/tailnet/-/dns/split-dns", fn _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error} = ApiClient.split_dns_get(@token)
    end
  end

  describe "split_dns_patch/2" do
    test "PATCHes the per-domain upsert — NEVER a full-replace PUT" do
      # The hostile-method pin: a PUT here would rewrite the customer's
      # OTHER split-DNS routes (ADR-0040 §12's blast-radius rule).
      stub(Req, :put, fn _req, _opts -> flunk("split DNS is patched, never PUT") end)

      expect_request(:patch, "/api/v2/tailnet/-/dns/split-dns", fn opts ->
        assert opts[:json] == %{"apps.customer.com" => ["10.43.0.20"]}
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      assert :ok = ApiClient.split_dns_patch(@token, %{"apps.customer.com" => ["10.43.0.20"]})
    end

    test "a nil value unsets the domain through the same PATCH" do
      expect_request(:patch, "/api/v2/tailnet/-/dns/split-dns", fn opts ->
        assert opts[:json] == %{"apps.customer.com" => nil}
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      assert :ok = ApiClient.split_dns_patch(@token, %{"apps.customer.com" => nil})
    end

    test "401 maps to :unauthorized (the write path hears the same verdict)" do
      expect_request(:patch, "/api/v2/tailnet/-/dns/split-dns", fn _opts ->
        {:ok, %Req.Response{status: 401, body: %{"error" => "expired"}}}
      end)

      assert {:error, :unauthorized} = ApiClient.split_dns_patch(@token, %{"d" => nil})
    end

    test "403 maps to :forbidden on the write path too" do
      expect_request(:patch, "/api/v2/tailnet/-/dns/split-dns", fn _opts ->
        {:ok, %Req.Response{status: 403, body: %{"error" => "denied"}}}
      end)

      assert {:error, :forbidden} = ApiClient.split_dns_patch(@token, %{"d" => nil})
    end
  end
end
