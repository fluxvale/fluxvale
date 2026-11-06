defmodule FluxValeWeb.Api.AccessDomainRouteTest do
  @moduledoc false

  # #482 P2: the access-domain family's wire contract — the provider's
  # register/list/inspect/resume/remove. The routed `:register` is the
  # raw create action (row only, no Certificate mint — that is the
  # operation's leg), so no cluster stubs beyond the suspend/resume
  # funnels' own seams.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures

  @domain_name "apps.customer.com"

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  # The register/resume entitlement gate: member + paid-once + funded
  # (welcome credits never qualify).
  defp paid_member! do
    user = elem(ApiPat.member!(), 0)
    org = BillingFixtures.mark_user_paid!(user)
    {user, org}
  end

  setup do
    # The suspend/resume funnels' cluster seams — default success (the
    # changes_test stance); the fixture rows carry no attached
    # instances, so the limbs around these are no-ops.
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    :ok
  end

  describe "POST /api/v1/access-domains" do
    test "registers a pending :custom row for the actor's org", %{conn: conn} do
      {user, org} = paid_member!()
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-domains", %{
          "data" => %{
            "type" => "access_domain",
            "attributes" => %{"domain" => @domain_name}
          }
        })

      assert %{"data" => row} = json_response(conn, 201)
      assert row["type"] == "access_domain"
      assert row["attributes"]["domain"] == @domain_name
      assert row["attributes"]["kind"] == "custom"

      # The core promise (verify-by-issuance): the row claims nothing.
      assert row["attributes"]["state"] == "pending"

      # The pinned public field set — id rides the document, the rest
      # is the attribute key set exactly.
      attr_keys = Map.keys(row["attributes"])

      assert MapSet.new(attr_keys) == MapSet.new(["domain", "kind", "state"])

      # cert_secret_ref is an internal k8s object name — never API
      # surface.
      refute Map.has_key?(row["attributes"], "cert_secret_ref")

      fresh = AccessDomain.get_by_id!(row["id"], authorize?: false)
      assert fresh.organization_id == org.id
      assert fresh.kind == :custom
      assert fresh.state == :pending
    end

    test "the domain lands canonical (trimmed + downcased)", %{conn: conn} do
      {user, _org} = paid_member!()
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-domains", %{
          "data" => %{
            "type" => "access_domain",
            "attributes" => %{"domain" => "  Apps.Customer.COM  "}
          }
        })

      assert %{"data" => %{"attributes" => %{"domain" => "apps.customer.com"}}} =
               json_response(conn, 201)
    end

    test "a foreign organization_id is Forbidden — the wire names only the caller's own orgs",
         %{conn: conn} do
      # #408: the argument is member-fenced. The foreign org is paid so
      # membership is the only failing fence (the ops suite's stance).
      {user, _org} = paid_member!()
      {foreign, _foreign_owner} = BillingFixtures.grant_free_org!()
      BillingFixtures.mark_paid!(foreign)
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-domains", %{
          "data" => %{
            "type" => "access_domain",
            "attributes" => %{
              "domain" => "foreign.example.com",
              "organization_id" => foreign.id
            }
          }
        })

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)
    end

    test "an unpaid member is Forbidden — the entitlement gate rides the wire", %{conn: conn} do
      # ADR-0040 Amendment 2: a paid-once, funded account. The JIT
      # member is welcome-funded and never paid.
      {user, _pat} = ApiPat.member!()
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-domains", %{
          "data" => %{
            "type" => "access_domain",
            "attributes" => %{"domain" => "unpaid.example.com"}
          }
        })

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)
    end
  end

  describe "GET /api/v1/organizations/:organization_id/access-domains" do
    test "lists the org's rows with the pinned public field set", %{conn: conn} do
      {user, org} = paid_member!()
      first = custom_domain!(user, org, "first.example.com")
      second = custom_domain!(user, org, "second.example.com")
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/access-domains")

      assert %{"data" => rows} = json_response(conn, 200)
      assert length(rows) == 2

      row_ids = Enum.map(rows, & &1["id"])
      assert MapSet.new(row_ids) == MapSet.new([first.id, second.id])

      one = Enum.find(rows, &(&1["id"] == first.id))
      assert one["type"] == "access_domain"
      assert one["attributes"]["domain"] == "first.example.com"
      assert one["attributes"]["kind"] == "custom"
      assert one["attributes"]["state"] == "pending"

      one_keys = Map.keys(one["attributes"])

      assert MapSet.new(one_keys) == MapSet.new(["domain", "kind", "state"])

      refute Map.has_key?(one["attributes"], "cert_secret_ref")
    end

    test "another org's domains are invisible — a foreign org lists empty", %{conn: conn} do
      {user, org} = paid_member!()
      custom_domain!(user, org, "mine.example.com")

      # The foreign org rides grant_free_org! (the gateway suite's
      # stance): no gate runs on its authorize-free fixture insert, and
      # the route test only needs the membership fence to bite.
      {other_org, other_owner} = BillingFixtures.grant_free_org!()
      custom_domain!(other_owner, other_org, "theirs.example.com")
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/access-domains")

      assert %{"data" => rows} = json_response(conn, 200)
      assert [%{"attributes" => %{"domain" => "mine.example.com"}}] = rows

      foreign =
        build_conn()
        |> auth(pat)
        |> get("/api/v1/organizations/#{other_org.id}/access-domains")

      assert %{"data" => []} = json_response(foreign, 200)
    end
  end

  describe "GET /api/v1/access-domains/:id" do
    test "returns the record's public surface", %{conn: conn} do
      {user, org} = paid_member!()
      domain = custom_domain!(user, org, @domain_name)
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/access-domains/#{domain.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == domain.id
      assert row["attributes"]["domain"] == @domain_name
      assert row["attributes"]["kind"] == "custom"
      assert row["attributes"]["state"] == "pending"
      refute Map.has_key?(row["attributes"], "cert_secret_ref")
    end

    test "the platform row is inspectable — kind platform", %{conn: conn} do
      {user, org} = paid_member!()
      domain = platform_domain!(org)
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/access-domains/#{domain.id}")

      assert %{"data" => %{"attributes" => %{"kind" => "platform", "state" => "verified"}}} =
               json_response(conn, 200)
    end

    test "a non-member's row is 404 — the read policy filters", %{conn: conn} do
      {member, org} = paid_member!()
      domain = custom_domain!(member, org, @domain_name)
      {outsider, _outsider_org} = paid_member!()
      pat = ApiPat.mint!(outsider.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/access-domains/:id/resume" do
    test "resumes a suspended domain — the row back to :verified", %{conn: conn} do
      {user, org} = paid_member!()
      domain = suspended_domain!(user, org)
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-domains/#{domain.id}/resume", %{
          "data" => %{"type" => "access_domain", "id" => domain.id, "attributes" => %{}}
        })

      assert %{"data" => %{"attributes" => %{"state" => "verified"}}} = json_response(conn, 200)
    end

    test "a drained wallet is Forbidden — the funded gate rides the wire", %{conn: conn} do
      {user, org} = paid_member!()
      domain = suspended_domain!(user, org)
      BillingFixtures.drain_wallet!(org)
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-domains/#{domain.id}/resume", %{
          "data" => %{"type" => "access_domain", "id" => domain.id, "attributes" => %{}}
        })

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)
    end

    test "a non-member's row is 404 — the resume never sees it", %{conn: conn} do
      {member, org} = paid_member!()
      domain = suspended_domain!(member, org)
      {outsider, _outsider_org} = paid_member!()
      pat = ApiPat.mint!(outsider.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-domains/#{domain.id}/resume", %{
          "data" => %{"type" => "access_domain", "id" => domain.id, "attributes" => %{}}
        })

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/access-domains/:id" do
    test "removes a :custom row", %{conn: conn} do
      {user, org} = paid_member!()
      domain = custom_domain!(user, org, @domain_name)
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert conn.status == 200

      assert {:error, _not_found} = AccessDomain.get_by_id(domain.id, actor: user)
    end

    test "the platform row is refused — it is load-bearing", %{conn: conn} do
      {user, org} = paid_member!()
      domain = platform_domain!(org)
      pat = ApiPat.mint!(user.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "not removable"
    end

    test "a non-member's row is 404 — nothing removed", %{conn: conn} do
      {member, org} = paid_member!()
      domain = custom_domain!(member, org, @domain_name)
      {outsider, _outsider_org} = paid_member!()
      pat = ApiPat.mint!(outsider.email, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)

      assert AccessDomain.get_by_id!(domain.id, authorize?: false)
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Test precondition through the action, authorize?: false (the seeds
  # posture): the raw register action lands the :pending :custom row
  # without the operation's Certificate leg. `user` is the org's member
  # — the tenancy change reads the org from the argument.
  defp custom_domain!(user, org, name) do
    AccessDomain
    |> Ash.Changeset.for_create(
      :register,
      %{domain: name, organization_id: org.id},
      actor: user,
      authorize?: false
    )
    |> Ash.create!()
  end

  # The system-minted platform row through its own action — policies
  # forbid member calls, so the precondition is authorize?: false.
  defp platform_domain!(org) do
    base = Application.fetch_env!(:flux_vale, :instances_base_domain)

    AccessDomain
    |> Ash.Changeset.for_create(
      :mint_platform,
      %{domain: base, organization_id: org.id},
      authorize?: false
    )
    |> Ash.create!()
  end

  # The legacy suspended shape the resume serves: verified first (the
  # state funnel's precondition), then the ladder's demotion — both
  # authorize?: false (system-only actions).
  defp suspended_domain!(user, org) do
    pending = custom_domain!(user, org, @domain_name)
    {:ok, verified} = AccessDomain.mark_verified(pending, authorize?: false)
    {:ok, suspended} = AccessDomain.mark_suspended(verified, authorize?: false)

    suspended
  end
end
