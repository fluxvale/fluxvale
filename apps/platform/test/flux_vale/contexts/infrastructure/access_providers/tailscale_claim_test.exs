defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.ClaimTest do
  @moduledoc """
  The provider's tailnet-claiming half (ADR-0040 §3/§5) against stubbed
  K8s Secrets and a stubbed API client: the idempotent claim
  (read→union→set, no needless writes), the shared-tailnet unclaim rule
  (one route per tailnet+domain; the /32 comes off with the gateway's
  LAST claim), the observer's 401 drift limb, the api-credential Secret
  pair, and the TS_ROUTES manifest limb.
  """

  # async: false — the TS_ROUTES/unclaim-fallback tests mutate the
  # node-global :access_dns app env.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @domain "apps.customer.com"
  @resolver_ip "10.43.0.20"
  @ours @resolver_ip <> "/32"
  @token "tskey-api-xyz"

  # The claim entry shape (P2-14): string keys — the dns_claims map
  # round-trips through jsonb, so atom keys would come back as strings
  # and fork the readers. `tailnet` is the RECORDED suffix (what the
  # owner had typed at claim time), not a live re-read.
  defp claim_entry(ip, tailnet \\ "example.ts.net") do
    %{"ip" => ip, "tailnet" => tailnet}
  end

  setup do
    InstanceFixtures.local_cluster!()
    parent = self()

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :create, fn _kc, ns, name, data ->
      send(parent, {:secret_create, ns, name, data})
      {:ok, %{}}
    end)

    stub(Secret, :get_data, fn _kc, _ns, _name -> {:ok, %{"TS_API_TOKEN" => @token}} end)

    stub(Deployment, :apply_manifest, fn _kc, manifest ->
      send(parent, {:deployment_apply, manifest})
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim, :create, fn _kc,
                                                                           _ns,
                                                                           _name,
                                                                           _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.NetworkPolicy, :create, fn _kc, _ns, _name, _spec ->
      {:ok, %{}}
    end)

    stub(Deployment, :restart, fn _kc, _ns, _name -> {:ok, %{}} end)

    stub(Deployment, :status, fn _kc, _ns, _name ->
      {:ok,
       %{
         ready: 1,
         replicas: 1,
         actual_replicas: 1,
         updated: 1,
         generation: 1,
         observed_generation: 1
       }}
    end)

    stub(ApiClient, :devices_lookup, fn _token, hostname ->
      send(parent, {:devices_lookup, hostname})
      {:ok, %{id: "dev-777"}}
    end)

    stub(ApiClient, :routes_get, fn _token, id ->
      send(parent, {:routes_get, id})
      {:ok, %{advertised: [], enabled: []}}
    end)

    stub(ApiClient, :routes_set, fn _token, id, routes ->
      send(parent, {:routes_set, id, routes})
      :ok
    end)

    stub(ApiClient, :split_dns_get, fn _token ->
      send(parent, :split_dns_get)
      {:ok, %{}}
    end)

    stub(ApiClient, :split_dns_patch, fn _token, patch ->
      send(parent, {:split_dns_patch, patch})
      :ok
    end)

    {org, _owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org}
  end

  describe "claim_domain/3" do
    test "approves the /32 and adds the split-DNS route", %{org: org} do
      gateway = gateway_row!(org)

      assert {:ok, %{device_id: "dev-777", route: @ours}} =
               Tailscale.claim_domain(gateway, @domain, @resolver_ip)

      assert_received {:devices_lookup, hostname}
      assert hostname == gateway.hostname

      # Pre-enable: our /32 goes on even though the node advertised
      # nothing yet (documented API capability — §3).
      assert_received {:routes_set, "dev-777", [@ours]}
      assert_received {:split_dns_patch, %{@domain => [@resolver_ip]}}
    end

    test "a re-claim whose route and route-value already hold makes NO write", %{org: org} do
      gateway = gateway_row!(org)

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [@ours], enabled: [@ours]}}
      end)

      stub(ApiClient, :split_dns_get, fn _token ->
        {:ok, %{@domain => [@resolver_ip]}}
      end)

      reject(ApiClient, :routes_set, 3)
      reject(ApiClient, :split_dns_patch, 2)

      assert {:ok, %{device_id: "dev-777"}} =
               Tailscale.claim_domain(gateway, @domain, @resolver_ip)
    end

    test "unions with what is already enabled — the POST replaces", %{org: org} do
      gateway = gateway_row!(org)
      claim_with_enabled(gateway, ["10.0.0.1/32"])
    end

    test "the DNS value converges even when the route is already enabled", %{org: org} do
      gateway = gateway_row!(org)

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [], enabled: [@ours]}}
      end)

      reject(ApiClient, :routes_set, 3)

      assert {:ok, _claimed} = Tailscale.claim_domain(gateway, @domain, @resolver_ip)

      # Stale IP on the tailnet: one patch, not two writes.
      assert_received {:split_dns_patch, %{@domain => [@resolver_ip]}}
      refute_received {:routes_set, _id, _routes}
    end

    test "no token is :no_api_token, before any API call", %{org: org} do
      gateway = gateway_row!(org)

      stub(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(ApiClient, :devices_lookup, fn _t, _h -> flunk("no API call without a token") end)

      assert {:error, :no_api_token} = Tailscale.claim_domain(gateway, @domain, @resolver_ip)
    end

    test "an unknown node is :node_not_found", %{org: org} do
      gateway = gateway_row!(org)

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :not_found} end)
      reject(ApiClient, :routes_get, 2)

      assert {:error, :node_not_found} = Tailscale.claim_domain(gateway, @domain, @resolver_ip)
    end

    test "a rejected token propagates :unauthorized", %{org: org} do
      gateway = gateway_row!(org)

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :unauthorized} end)

      assert {:error, :unauthorized} = Tailscale.claim_domain(gateway, @domain, @resolver_ip)
    end

    test "a routes read failure surfaces from the claim, before any write", %{org: org} do
      gateway = gateway_row!(org)

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:error, %{status: 500, body: "boom"}}
      end)

      reject(ApiClient, :routes_set, 3)

      assert {:error, %{status: 500}} = Tailscale.claim_domain(gateway, @domain, @resolver_ip)
    end

    test "a split-DNS read failure surfaces from the claim, before any patch", %{org: org} do
      gateway = gateway_row!(org)

      stub(ApiClient, :split_dns_get, fn _token -> {:error, :network_error} end)
      reject(ApiClient, :split_dns_patch, 2)

      assert {:error, :network_error} = Tailscale.claim_domain(gateway, @domain, @resolver_ip)
    end
  end

  describe "unclaim_domain/2" do
    test "the gateway's LAST claim unsets the DNS route and disables the /32", %{org: org} do
      gateway = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [@ours], enabled: [@ours, "10.0.0.1/32"]}}
      end)

      assert :ok = Tailscale.unclaim_domain(gateway, @domain)

      assert_received {:split_dns_patch, %{@domain => nil}}

      # Read → difference → set: only OURS leaves; the stranger's route
      # must survive the POST's replace semantics.
      assert_received {:routes_set, "dev-777", ["10.0.0.1/32"]}
    end

    test "a shared tailnet keeps the DNS route (another gateway claims it)", %{org: org} do
      gateway = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      # The owner's own case: a second org's gateway on the SAME tailnet
      # still claims the domain — one route serves all of them (§3).
      _other =
        Ash.Seed.seed!(AccessGateway, %{
          organization_id: other_org!().id,
          hostname: "fv-00000009",
          monthly_cents: 200,
          state: :active,
          tailnet_domain: "example.ts.net",
          dns_claims: %{@domain => claim_entry(@resolver_ip)}
        })

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [@ours], enabled: [@ours]}}
      end)

      assert :ok = Tailscale.unclaim_domain(gateway, @domain)

      # The DNS route STAYS; this gateway's (now claim-less) node route
      # still goes — it is per-node plumbing.
      refute_received {:split_dns_patch, _patch}
      assert_received {:routes_set, "dev-777", []}
    end

    test "remaining claims keep the /32 — it serves all claimed domains", %{org: org} do
      gateway =
        with_claims(gateway_row!(org), %{
          @domain => claim_entry(@resolver_ip),
          "other.example.com" => claim_entry(@resolver_ip)
        })

      assert :ok = Tailscale.unclaim_domain(gateway, @domain)

      # The domain's route is unset; the /32 stays for the OTHER claim.
      assert_received {:split_dns_patch, %{@domain => nil}}
      refute_received {:routes_set, _id, _routes}
    end

    test "an already-disabled route makes no write", %{org: org} do
      gateway = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [], enabled: []}}
      end)

      assert :ok = Tailscale.unclaim_domain(gateway, @domain)

      assert_received {:split_dns_patch, %{@domain => nil}}
      refute_received {:routes_set, _id, _routes}
    end

    test "a vanished node unclaims as DNS-only — its routes died with it", %{org: org} do
      gateway = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :not_found} end)
      reject(ApiClient, :routes_get, 2)

      assert :ok = Tailscale.unclaim_domain(gateway, @domain)

      assert_received {:split_dns_patch, %{@domain => nil}}
      refute_received {:routes_set, _id, _routes}
    end

    test "no token is :no_api_token", %{org: org} do
      gateway =
        with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      stub(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(ApiClient, :split_dns_patch, fn _t, _p -> flunk("no API call without a token") end)

      assert {:error, :no_api_token} = Tailscale.unclaim_domain(gateway, @domain)
    end

    test "a non-404 node lookup failure fails the unclaim (only a vanished node is tolerated)",
         %{org: org} do
      gateway =
        with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      # The DNS unset lands (no other claimant), then the node lookup
      # fails for a REAL reason — that error must surface, not vanish.
      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :unauthorized} end)

      assert {:error, :unauthorized} = Tailscale.unclaim_domain(gateway, @domain)

      assert_received {:split_dns_patch, %{@domain => nil}}
    end

    test "a routes read failure during the disable surfaces", %{org: org} do
      gateway =
        with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      stub(ApiClient, :routes_get, fn _token, _id -> {:error, :network_error} end)

      assert {:error, :network_error} = Tailscale.unclaim_domain(gateway, @domain)

      refute_received {:routes_set, _id, _routes}
    end

    test "no claim entry and no resolver configured: the DNS unset lands, nothing else", %{
      org: org
    } do
      previous = Application.get_env(:flux_vale, :access_dns)

      on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

      Application.put_env(:flux_vale, :access_dns, nil)

      gateway = gateway_row!(org)

      assert :ok = Tailscale.unclaim_domain(gateway, @domain)

      assert_received {:split_dns_patch, %{@domain => nil}}
      refute_received {:routes_set, _id, _routes}
    end
  end

  describe "gateway_status/1 — the claims drift limb" do
    test "a valid token leaves the pod-level observation standing", %{org: org} do
      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:ok, %{id: "dev-777"}} end)

      assert {:ok, %{state: :active, message: "Connected to your tailnet"}} =
               Tailscale.gateway_status(gateway)
    end

    test "a 401 lands :needs_attention with the re-paste copy", %{org: org} do
      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :unauthorized} end)

      # P3-13's equality pin: the drift copy IS the provider's — the op
      # reads the same function, so two sentences for one rejection
      # cannot exist.
      assert {:ok, %{state: :needs_attention, message: message}} =
               Tailscale.gateway_status(gateway)

      assert message == Tailscale.token_drift_message(:unauthorized)
      assert message =~ "rejected"
    end

    test "a 403 lands the SCOPE copy — a different verdict, a different sentence", %{org: org} do
      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :forbidden} end)

      assert {:ok, %{state: :needs_attention, message: message}} =
               Tailscale.gateway_status(gateway)

      assert message == Tailscale.token_drift_message(:forbidden)
      assert message =~ "devices:routes"
      refute message == Tailscale.token_drift_message(:unauthorized)
    end

    test "a drifted claim IP converges within the pass (P2-4)", %{org: org} do
      put_access_dns()

      # The entry predates a fleet-side resolver move: recorded 9.9.9.9,
      # config now points at @resolver_ip.
      claimed =
        with_claims(gateway_row!(org), %{@domain => claim_entry("9.9.9.9")})

      gateway = with_token_ref(claimed, "api-credential-x")

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      # One per-domain PATCH converges the record...
      assert_received {:split_dns_patch, %{@domain => [@resolver_ip]}}
      # ...and ONE Deployment re-apply — a TS_ROUTES diff is a
      # pod-template change; the restart is how the new /32 reaches the
      # node (P2-4).
      assert_received {:deployment_apply, _manifest}

      # The stored entry now carries the converged IP (a real funnel
      # write, optimistic-locked).
      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims[@domain]["ip"] == @resolver_ip
    end

    test "a lost /32 is re-united within the pass (P2-6)", %{org: org} do
      put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      # A racing writer's POST replaced the enabled list without ours
      # (the API's replace semantics are exactly why this limb exists).
      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [], enabled: ["10.0.0.1/32"]}}
      end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      # Union, never replace: the stranger's route rides along.
      assert_received {:routes_set, "dev-777", [@ours, "10.0.0.1/32"]}
    end

    test "the RULED default-on claim: an active tokened gateway claims the platform domain",
         %{org: org} do
      put_access_dns()
      base = Application.fetch_env!(:flux_vale, :instances_base_domain)

      AccessDomain.mint_platform!(
        %{domain: base, organization_id: org.id},
        authorize?: false
      )

      gateway = with_token_ref(gateway_row!(org), "api-credential-x")

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      # The claim's two writes happened...
      assert_received {:routes_set, "dev-777", [@ours]}
      assert_received {:split_dns_patch, %{^base => [@resolver_ip]}}

      # ...and the row records the entry, with the RECORDED tailnet.
      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims[base] == claim_entry(@resolver_ip)
    end

    test "an already-claimed platform domain is not re-claimed (converges, no writes)", %{
      org: org
    } do
      put_access_dns()
      base = Application.fetch_env!(:flux_vale, :instances_base_domain)

      AccessDomain.mint_platform!(%{domain: base, organization_id: org.id}, authorize?: false)

      claimed =
        with_claims(gateway_row!(org), %{
          base => claim_entry(@resolver_ip),
          @domain => claim_entry(@resolver_ip)
        })

      gateway = with_token_ref(claimed, "api-credential-x")

      stub(ApiClient, :split_dns_get, fn _token -> {:ok, %{base => [@resolver_ip]}} end)

      # Routes already hold ours; the /32 is present; the entry matches
      # config: the pass makes NO tailnet write and NO row write.
      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [@ours], enabled: [@ours]}}
      end)

      reject(ApiClient, :routes_set, 3)
      reject(ApiClient, :split_dns_patch, 2)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "an unclaimed gateway with a token still verifies (the default-on claim's gate)",
         %{org: org} do
      gateway = with_token_ref(gateway_row!(org), "api-credential-x")

      # No platform row for the org, so the default-on claim has nothing
      # to claim — but the token verify (its gate) still runs.
      stub(ApiClient, :devices_lookup, fn _t, _h -> {:ok, %{id: "dev-777"}} end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "claims without a token ref make no API call", %{org: org} do
      gateway = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      stub(ApiClient, :devices_lookup, fn _t, _h -> flunk("no token, nothing to verify") end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "a flaky token check must not flap the row", %{org: org} do
      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :network_error} end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "an unreadable token stands down — nothing provable either way", %{org: org} do
      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(Secret, :get_data, fn _kc, _ns, _name -> {:ok, %{}} end)
      stub(ApiClient, :devices_lookup, fn _t, _h -> flunk("no token was read") end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "a pod problem dominates — the token is not even asked", %{org: org} do
      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(Deployment, :status, fn _kc, _ns, _name ->
        {:ok,
         %{
           ready: 0,
           replicas: 1,
           actual_replicas: 1,
           updated: 1,
           generation: 1,
           observed_generation: 1
         }}
      end)

      stub(ApiClient, :devices_lookup, fn _t, _h -> flunk("pod failure dominates") end)

      assert {:ok, %{state: :needs_attention, message: message}} =
               Tailscale.gateway_status(gateway)

      refute message == Tailscale.token_drift_message(:unauthorized)
    end
  end

  describe "the api-credential Secret pair" do
    test "write_api_credential stores TS_API_TOKEN and returns the ref", %{org: org} do
      gateway = gateway_row!(org)

      assert {:ok, %{api_token_secret_ref: ref}} =
               Tailscale.write_api_credential(gateway, "tskey-api-new")

      assert ref == "api-credential-" <> short_id(gateway)
      assert_received {:secret_create, ns, ^ref, %{"TS_API_TOKEN" => "tskey-api-new"}}
      assert ns == "fluxvale-access"
    end

    test "a Secret write failure surfaces from write_api_credential", %{org: org} do
      gateway = gateway_row!(org)

      expect(Secret, :create, fn _kc, _ns, _name, _data ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.write_api_credential(gateway, "tskey-api-new")
    end

    test "read_api_credential returns the token — internal only", %{org: org} do
      gateway = gateway_row!(org)

      assert {:ok, @token} = Tailscale.read_api_credential(gateway)
    end

    test "a non-404 Secret read failure surfaces (the caller decides, not the provider)",
         %{org: org} do
      gateway = gateway_row!(org)

      expect(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{}} = Tailscale.read_api_credential(gateway)
    end

    test "a malformed Secret is explicit", %{org: org} do
      gateway = gateway_row!(org)

      stub(Secret, :get_data, fn _kc, _ns, _name -> {:ok, %{}} end)

      assert {:error, :api_token_malformed} = Tailscale.read_api_credential(gateway)
    end

    test "an absent Secret is :no_api_token", %{org: org} do
      gateway = gateway_row!(org)

      stub(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:error, :no_api_token} = Tailscale.read_api_credential(gateway)
    end
  end

  describe "teardown_gateway/1 — the unclaim-all limb (P1-1)" do
    # P1-1's rule: no dangling tailnet state and no orphaned API key,
    # from EVERY exit.
    test "reverts every claim, drops the /32 with the last claim, then deletes the objects",
         %{org: org} do
      gateway =
        with_claims(gateway_row!(org), %{
          @domain => claim_entry(@resolver_ip),
          "other.example.com" => claim_entry(@resolver_ip)
        })

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [@ours], enabled: [@ours]}}
      end)

      expect(Deployment, :delete, fn _kc, _ns, _n -> :ok end)

      expect(Secret, :delete, 3, fn _kc, _ns, secret_name ->
        assert secret_name in [
                 name_prefix(gateway, "serve-config"),
                 name_prefix(gateway, "credential"),
                 name_prefix(gateway, "api-credential")
               ]

        :ok
      end)

      expect(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim, :delete, fn _kc, _ns, _claim ->
        :ok
      end)

      assert :ok = Tailscale.teardown_gateway(gateway)

      # Both domains unset (no other claimant on the tailnet)...
      assert_received {:split_dns_patch, %{@domain => nil}}
      assert_received {:split_dns_patch, %{"other.example.com" => nil}}

      # ...and the /32 dropped exactly once — with the LAST claim (the
      # first unclaim still has the other entry remaining).
      assert_received {:routes_set, "dev-777", []}
      refute_received {:routes_set, _id, _other}
    end

    test "an unclaim failure FAILS the teardown — nothing is deleted", %{org: org} do
      gateway = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      # The DNS unset lands; the node lookup then fails for a REAL
      # reason — the teardown must refuse, not strand the route.
      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :unauthorized} end)

      reject(Deployment, :delete, 3)
      reject(Secret, :delete, 3)
      reject(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim, :delete, 3)

      assert {:error, {:unclaim_failed, @domain, :unauthorized}} =
               Tailscale.teardown_gateway(gateway)
    end

    test "claims without a readable token fail the teardown honestly", %{org: org} do
      gateway = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})

      stub(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(ApiClient, :split_dns_patch, fn _t, _p -> flunk("no API call without a token") end)
      reject(Deployment, :delete, 3)

      assert {:error, {:unclaim_failed, @domain, :no_api_token}} =
               Tailscale.teardown_gateway(gateway)
    end
  end

  describe "cleanup_failed_provision/1 — the api-credential delete (P1-1)" do
    test "deletes the api-credential alongside the credential (keys first)", %{org: org} do
      gateway = gateway_row!(org)
      parent = self()

      stub(Secret, :delete, fn _kc, _ns, secret_name ->
        send(parent, {:deleted, secret_name})
        :ok
      end)

      stub(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim, :delete, fn _kc, _ns, _claim ->
        :ok
      end)

      assert :ok = Tailscale.cleanup_failed_provision(gateway)

      assert_received {:deleted, first}
      assert first == name_prefix(gateway, "credential")

      assert_received {:deleted, second}
      assert second == name_prefix(gateway, "api-credential")
    end
  end

  describe "the reconcile limb's stand-downs (one-shot per pass, no flapping)" do
    # Every arm below is the same stance: the limb's API/funnel work
    # failed, the pass LOGS and stands down, the pod-level observation
    # stands, and the next tick re-decides. Pinned once per arm so a
    # refactor cannot turn a stand-down into a crash or a flap.
    test "a failed claims write is skipped — the drift side effects landed anyway", %{org: org} do
      put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry("9.9.9.9")})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(AccessGateway, :update_claims, fn _gw, _attrs, _opts -> {:error, :forced_db} end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      # The tailnet-side convergence happened; only the row write skipped.
      assert_received {:split_dns_patch, %{@domain => [@resolver_ip]}}
      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims[@domain]["ip"] == "9.9.9.9"
    end

    test "a failed convergence PATCH stands down without re-applying the Deployment", %{
      org: org
    } do
      put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry("9.9.9.9")})
      gateway = with_token_ref(claimed, "api-credential-x")

      # The provision leg's own apply is not under observation.
      drain_provision()

      stub(ApiClient, :split_dns_patch, fn _token, _patch -> {:error, :network_error} end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      # No convergence, no restart — the next tick re-decides.
      refute_received {:deployment_apply, _manifest}
      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims[@domain]["ip"] == "9.9.9.9"
    end

    test "a node lookup failure during the route re-union stands down", %{org: org} do
      put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      # First devices_lookup serves the token verify; the re-union's
      # own lookup fails for a real reason.
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(ApiClient, :devices_lookup, fn _token, _hostname ->
        n = Agent.get_and_update(calls, fn c -> {c, c + 1} end)
        if n == 0, do: {:ok, %{id: "dev-777"}}, else: {:error, :network_error}
      end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims[@domain]["ip"] == @resolver_ip
    end

    test "a routes read failure during the re-union stands down", %{org: org} do
      put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(ApiClient, :routes_get, fn _token, _id -> {:error, :network_error} end)
      reject(ApiClient, :routes_set, 3)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "a failed /32 re-union stands down", %{org: org} do
      put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry(@resolver_ip)})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(ApiClient, :routes_get, fn _token, _id ->
        {:ok, %{advertised: [], enabled: ["10.0.0.1/32"]}}
      end)

      stub(ApiClient, :routes_set, fn _token, _id, _routes -> {:error, :quota} end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)
    end

    test "a failed Deployment re-apply stands down", %{org: org} do
      previous = put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry("9.9.9.9")})
      gateway = with_token_ref(claimed, "api-credential-x")

      stub(Deployment, :apply_manifest, fn _kc, _manifest ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)
    end

    test "no cluster for the Deployment re-apply stands down", %{org: org} do
      previous = put_access_dns()

      claimed = with_claims(gateway_row!(org), %{@domain => claim_entry("9.9.9.9")})
      gateway = with_token_ref(claimed, "api-credential-x")

      # The kubeconfig resolves for the pod read and the token read,
      # then the cluster goes away before the re-apply.
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(K8s, :kubeconfig, fn _ref ->
        n = Agent.get_and_update(calls, fn c -> {c, c + 1} end)
        if n < 2, do: {:ok, %{}}, else: {:error, :db_down}
      end)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)
    end

    test "a failed default-on claim stands down with the row unchanged", %{org: org} do
      put_access_dns()
      base = Application.fetch_env!(:flux_vale, :instances_base_domain)

      AccessDomain.mint_platform!(%{domain: base, organization_id: org.id}, authorize?: false)

      gateway = with_token_ref(gateway_row!(org), "api-credential-x")

      # claim_domain's own split-DNS read fails — the default claim
      # stands down, nothing is recorded, the next tick re-decides.
      stub(ApiClient, :split_dns_get, fn _token -> {:error, :network_error} end)
      reject(ApiClient, :split_dns_patch, 2)

      assert {:ok, %{state: :active}} = Tailscale.gateway_status(gateway)

      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims == nil
    end
  end

  describe "the TS_ROUTES manifest limb" do
    test "a configured resolver advertises its /32", %{org: org} do
      put_access_dns()

      gateway = gateway_row!(org)
      then_assert_env(gateway, "TS_ROUTES", @ours)
    end

    test "no resolver configured: no TS_ROUTES, the manifest is the ADR-0039 shape", %{org: org} do
      previous = Application.get_env(:flux_vale, :access_dns)

      on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

      Application.put_env(:flux_vale, :access_dns, nil)

      gateway = gateway_row!(org)
      then_refute_env(gateway, "TS_ROUTES")
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp other_org! do
    {org, _owner} = BillingFixtures.grant_free_org!()
    org
  end

  # A real row through the create action — the provider's own provision
  # leg runs against the setup's capturing stubs (tailscale_test's
  # stance: these tests ARE the provider).
  defp gateway_row!(org) do
    gateway =
      AccessGateway.create!(
        %{
          organization_id: org.id,
          monthly_cents: 200,
          tailnet_domain: "example.ts.net",
          auth_key: "tskey"
        },
        authorize?: false
      )

    gateway
    |> Ash.Changeset.for_update(
      :update_state,
      %{state: :active, status_message: "Connected"},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp with_claims(gateway, claims) do
    Ash.update!(gateway, %{dns_claims: claims},
      action: :update_claims,
      authorize?: false
    )
  end

  defp with_token_ref(gateway, ref) do
    Ash.update!(gateway, %{api_token_secret_ref: ref},
      action: :set_api_token_ref,
      authorize?: false
    )
  end

  defp claim_with_enabled(gateway, enabled) do
    stub(ApiClient, :routes_get, fn _token, _id ->
      {:ok, %{advertised: [], enabled: enabled}}
    end)

    assert {:ok, _claimed} = Tailscale.claim_domain(gateway, @domain, @resolver_ip)

    # Union, not replace: the stranger's route rides along (§12's rule).
    assert_received {:routes_set, "dev-777", [@ours | ^enabled]}
  end

  defp short_id(gateway) do
    gateway.id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(-10, 10)
  end

  # The provider's per-gateway object names — the same rule the
  # assertions pin (a local mirror of the provider's private helper).
  defp name_prefix(gateway, prefix), do: "#{prefix}-#{short_id(gateway)}"

  # Consume the create leg's captures so later refutes only see what
  # the code under observation sent.
  defp drain_provision do
    receive do
      {:secret_create, _ns, _name, _data} -> drain_provision()
      {:deployment_apply, _manifest} -> drain_provision()
      _other -> drain_provision()
    after
      0 -> :ok
    end
  end

  defp put_access_dns do
    previous = Application.get_env(:flux_vale, :access_dns)

    # Registered BEFORE the mutation (CodeRabbit's leak nit): a failure
    # mid-test still restores the file's config.
    on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

    Application.put_env(:flux_vale, :access_dns, resolver_ip: @resolver_ip)
    previous
  end

  defp then_assert_env(gateway, env_name, value) do
    manifest = deployment_manifest!()

    env =
      manifest["spec"]["template"]["spec"]["containers"]
      |> hd()
      |> Map.fetch!("env")
      |> Map.new(&{&1["name"], &1})

    assert env[env_name]["value"] == value
    gateway
  end

  defp then_refute_env(gateway, env_name) do
    manifest = deployment_manifest!()

    names =
      manifest["spec"]["template"]["spec"]["containers"]
      |> hd()
      |> Map.fetch!("env")
      |> Enum.map(& &1["name"])

    refute env_name in names
    gateway
  end

  defp deployment_manifest! do
    assert_received {:deployment_apply, manifest}
    manifest
  end
end
