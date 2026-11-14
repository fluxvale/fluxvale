defmodule FluxValeWeb.Api.GatewayRouteTest do
  @moduledoc false

  # #360: the gateway family's wire contract — the Access tab's own
  # surface (status read, enable, resume, attach/detach), with the
  # provider stubbed the way every gateway suite stubs it.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  # The gateway's enable gate: member + funded + PAID once (welcome
  # credits never qualify).
  defp paid_member! do
    user = elem(ApiPat.member!(), 0)
    org = BillingFixtures.mark_user_paid!(user)
    {user, org}
  end

  setup do
    InstanceFixtures.local_cluster!()

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
    # The provider's attach limb plays the row-create and stops there
    # (the attach op suite's own stance).
    stub(Tailscale, :attach_instance, fn gateway, instance ->
      {:ok,
       AccessRoute.create!(
         %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
         authorize?: false
       )}
    end)

    stub(Tailscale, :detach_instance, fn _gateway, _instance -> :ok end)

    # The access-edge limbs (the attach op suite's default stubs).
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)
    stub(Middleware, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    :ok
  end

  describe "GET /api/v1/organizations/:organization_id/access-gateway" do
    test "404s with no gateway, returns the org's row once enabled", %{conn: conn} do
      {user, org} = paid_member!()
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/access-gateway")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)

      gateway = AccessFixtures.gateway!(org)

      fresh =
        build_conn()
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/access-gateway")

      assert %{"data" => row} = json_response(fresh, 200)
      assert row["type"] == "access_gateway"
      assert row["id"] == gateway.id
      assert row["attributes"]["state"] == "active"
      assert row["attributes"]["monthly_cents"] == gateway.monthly_cents
      # #771: the claim path's readable half rides the wire — a bool
      # and the claimed domain names, never the map's values.
      assert row["attributes"]["api_token_set"] == false
      assert row["attributes"]["claimed_domains"] == []

      # The credential refs and the #613 operator-truth columns are
      # private by design — never on the wire, whoever the actor.
      refute Map.has_key?(row["attributes"], "credential_secret_ref")
      refute Map.has_key?(row["attributes"], "api_token_secret_ref")
      refute Map.has_key?(row["attributes"], "needs_attention_since")
      refute Map.has_key?(row["attributes"], "token_set_at")
      refute Map.has_key?(row["attributes"], "dns_claims")
    end

    test "the claim path's readable half: token set and claimed domain names (#771)", %{
      conn: conn
    } do
      {user, org} = paid_member!()
      pat = ApiPat.mint!(user, ["gateways:read"])

      gateway =
        org
        |> AccessFixtures.gateway!()
        |> AccessGateway.set_api_token_ref!(
          %{api_token_secret_ref: "tok-stub"},
          authorize?: false
        )

      claimed =
        AccessGateway.update_claims!(
          gateway,
          %{dns_claims: %{"apps.customer.com" => %{"ip" => "100.64.0.1"}}},
          authorize?: false
        )

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/access-gateway")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["attributes"]["api_token_set"] == true
      assert row["attributes"]["claimed_domains"] == ["apps.customer.com"]

      # The claims map itself — its resolver IPs and tailnet data —
      # stays private.
      refute Map.has_key?(row["attributes"], "dns_claims")
      assert claimed.id == row["id"]
    end

    test "an admin PAT reads a foreign org's row member-shaped — the machine-API arm of the blanket (#644)",
         %{conn: conn} do
      {_member, own_org} = paid_member!()
      {stranger_org, _owner} = BillingFixtures.grant_free_org!()

      stranger_org
      |> AccessFixtures.gateway!(state: :needs_attention)
      |> AccessGateway.set_api_token_ref!(%{api_token_secret_ref: "tok-stub"}, authorize?: false)

      # ADR-0047: PAT callers fall past the blanket bypass to the
      # member-shaped policies — a foreign org's gateway 404s exactly
      # as a member's would. The cross-org read the console renders
      # rides the session, not the wire (pinned in the live suites).
      admin_pat = ApiPat.mint!(AccountsFixtures.platform_admin!(), ["gateways:read"])

      admin =
        build_conn()
        |> auth(admin_pat)
        |> get("/api/v1/organizations/#{stranger_org.id}/access-gateway")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(admin, 404)

      # Non-public columns stay off the wire whoever the actor — the
      # refutes ride the member's own-org row below in this suite.
      assert own_org.id != stranger_org.id
    end
  end

  describe "POST /api/v1/access-gateways" do
    test "enables the org — 201, and the price is the config's, not the body's", %{conn: conn} do
      {user, _org} = paid_member!()
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{
              "tailnet_domain" => "example.ts.net",
              "auth_key" => "tskey-test",
              "monthly_cents" => 0
            }
          }
        })

      assert %{"data" => row} = json_response(conn, 201)

      # The panel feeds the config figure; the API must not let a
      # caller price their own gateway — the create pins it.
      assert row["attributes"]["monthly_cents"] ==
               Application.fetch_env!(:flux_vale, :access_gateway)[:monthly_cents]

      assert row["attributes"]["state"] == "provisioning"

      # The auth key never comes back (ADR-0039 §4: no read-back).
      refute Map.has_key?(row["attributes"], "auth_key")
    end

    test "a foreign org_id is Forbidden — the wire names only the caller's own orgs", %{
      conn: conn
    } do
      # #408: the argument is the live context input, member-fenced. A
      # foreign org (this caller is not a member, whatever its wallet)
      # is refused outright now, not silently re-pinned.
      {user, org} = paid_member!()

      {_other_user, other_org} = paid_member!()

      refute other_org.id == org.id

      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{
              "organization_id" => other_org.id,
              "tailnet_domain" => "example.ts.net",
              "auth_key" => "tskey-test"
            }
          }
        })

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)
    end

    test "naming the caller's own org lands the row there (#408)", %{conn: conn} do
      {user, org} = paid_member!()

      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{
              "organization_id" => org.id,
              "tailnet_domain" => "example.ts.net",
              "auth_key" => "tskey-test"
            }
          }
        })

      assert %{"data" => %{"attributes" => %{"organization_id" => named}}} =
               json_response(conn, 201)

      assert named == org.id
    end
  end

  describe "PATCH /api/v1/access-gateways/:id/resume" do
    test "resumes a suspended gateway for a funded org (provider stubbed)", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org, state: :suspended)
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-gateways/#{gateway.id}/resume", %{
          "data" => %{"type" => "access_gateway", "id" => gateway.id, "attributes" => %{}}
        })

      assert %{"data" => %{"attributes" => %{"state" => "provisioning"}}} =
               json_response(conn, 200)
    end
  end

  describe "POST /api/v1/access-gateways/:gateway_id/attachments" do
    test "attaches a private instance — 201 with the pairing row", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, user)
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      # Generic-action shape: flat, the route row's public attributes.
      assert body = json_response(conn, 201)
      assert body["gateway_id"] == gateway.id
      assert body["instance_id"] == instance.id
      assert body["route_key"] == "8443"
    end

    test "a public instance is refused with the operation's own words", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.public_instance!(org, user)
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "not private"
    end

    test "a suspended gateway refuses attach — it is not serving", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org, state: :suspended)
      instance = AccessFixtures.private_instance!(org, user)
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "the gateway is not serving right now"
    end

    test "a never-deployed private instance refuses attach", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)

      version = InstanceFixtures.app_version!()

      # Private but never deployed (no namespace) — the panel's
      # attachable list only shows deployed rows; the API answers the
      # crafted request with the operation's own refusal. (One cluster
      # row rides the setup — ResolveCluster pins it.)
      instance =
        version
        |> InstanceFixtures.instance!(user)
        |> InstanceFixtures.pin!(exposure: :private)

      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "has not finished setting up"
    end

    test "a dual-member actor cannot pair across orgs — both verbs refuse", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)

      # The actor's second membership: every authorized read passes
      # (the actor belongs to both orgs), so the pairing's own org
      # fence is what bites — the operation's, not a policy's. The
      # org needs a funded wallet for the instance create itself.
      {other_org, _other_owner} = BillingFixtures.grant_free_org!()

      {:ok, wallet} = FluxVale.Billing.ensure_wallet(other_org)
      {:ok, _funding} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

      Membership.create!(
        %{organization_id: other_org.id, user_id: user.id, role: :member},
        authorize?: false
      )

      instance = AccessFixtures.private_instance!(other_org, user)
      pat = ApiPat.mint!(user, ["gateways:write"])

      attach =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      assert %{"errors" => [%{"detail" => detail}]} = json_response(attach, 400)
      assert detail =~ "the instance belongs to another organization"

      detach =
        build_conn()
        |> auth(pat)
        |> delete("/api/v1/access-gateways/#{gateway.id}/attachments/#{instance.id}")

      assert %{"errors" => [%{"detail" => detach_detail}]} = json_response(detach, 400)
      assert detach_detail =~ "the instance belongs to another organization"
    end

    test "a provider failure mid-attach passes the raw error through — no guard copy", %{
      conn: conn
    } do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, user)

      stub(Tailscale, :attach_instance, fn _gateway, _instance ->
        {:error, %Error{reason: :timeout, message: "provider timed out"}}
      end)

      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      assert %{"errors" => [%{"status" => "500"} | _rest]} = json_response(conn, 500)
    end
  end

  describe "DELETE /api/v1/access-gateways/:gateway_id/attachments/:instance_id" do
    test "detaches — idempotent success", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, user)

      _route =
        FluxVale.Infrastructure.attach_instance(gateway, instance, authorize?: false)

      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-gateways/#{gateway.id}/attachments/#{instance.id}")

      assert %{"success" => true} = json_response(conn, 200)
    end
  end

  describe "PATCH /api/v1/access-gateways/:id/api-token (#760)" do
    test "the owner stores the token — 200, no token anywhere on the wire", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)

      stub(Tailscale, :write_api_credential, fn gw, token ->
        assert gw.id == gateway.id
        assert token == "tskey-api-ROUTE-secret"
        {:ok, %{api_token_secret_ref: "api-credential-abc"}}
      end)

      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-gateways/#{gateway.id}/api-token", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{"api_token" => "tskey-api-ROUTE-secret"}
          }
        })

      assert %{"data" => row} = json_response(conn, 200)
      assert row["attributes"]["api_token_set"] == true
      assert row["attributes"]["claimed_domains"] == []
      refute Map.has_key?(row["attributes"], "api_token")
      refute conn.resp_body =~ "ROUTE-secret"

      stored = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert stored.api_token_secret_ref == "api-credential-abc"
    end

    test "a read-only token is refused by the scope gate — 403", %{conn: conn} do
      {user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)

      pat = ApiPat.mint!(user, ["gateways:read"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-gateways/#{gateway.id}/api-token", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{"api_token" => "tskey-api-ROUTE-secret"}
          }
        })

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)

      stored = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert stored.api_token_secret_ref == nil
    end

    test "a plain member of the org cannot paste — 403 Forbidden", %{conn: conn} do
      {_owner_user, org} = paid_member!()
      gateway = AccessFixtures.gateway!(org)

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      pat = ApiPat.mint!(member, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-gateways/#{gateway.id}/api-token", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{"api_token" => "tskey-api-ROUTE-secret"}
          }
        })

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)

      stored = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert stored.api_token_secret_ref == nil
    end
  end
end
