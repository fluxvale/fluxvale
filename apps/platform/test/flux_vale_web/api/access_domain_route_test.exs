defmodule FluxValeWeb.Api.AccessDomainRouteTest do
  @moduledoc false

  # #482 P2: the access-domain family's wire contract — the provider's
  # register/list/inspect/resume/remove. Both writes run the FULL
  # flow: register mints the wildcard Certificate inside the create's
  # transaction (the MintCertificate change — panel parity), and the
  # routed remove calls Operations.RemoveAccessDomain through the
  # domain seam (unclaim, render, cert safe-delete, then the row).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Accounts
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

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
    verify_on_exit!()

    # The register action's cluster leg and the remove's cert
    # safe-delete — default success; expect-ed where a test proves a
    # limb fired. The fixture helpers ride the stubs; the suspend/
    # resume funnels' seams below are no-ops for rows with no attached
    # instances.
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)
    stub(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200, body: %{}}} end)
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    :ok
  end

  describe "POST /api/v1/access-domains" do
    test "registers a pending :custom row and mints the Certificate", %{conn: conn} do
      {user, org} = paid_member!()
      pat = ApiPat.mint!(user, ["gateways:write"])
      config = Application.fetch_env!(:flux_vale, :access_domains)

      # The mint is panel-parity: the wildcard Certificate lands with
      # the row, inside the create's transaction.
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["kind"] == "Certificate"
        assert manifest["metadata"]["namespace"] == config[:certificate_namespace]
        assert manifest["spec"]["dnsNames"] == ["*.#{@domain_name}"]
        assert manifest["spec"]["secretName"] =~ ~r/^access-domain-[0-9a-f]{10}$/

        assert manifest["spec"]["issuerRef"]["name"] == config[:issuer]

        {:ok, %{status: 201, body: manifest}}
      end)

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
      assert row["attributes"]["organization_id"] == org.id

      # The pinned public field set — id rides the document, the rest
      # is the attribute key set exactly.
      attr_keys = Map.keys(row["attributes"])

      assert MapSet.new(attr_keys) ==
               MapSet.new(["domain", "kind", "organization_id", "state"])

      # cert_secret_ref is an internal k8s object name — never API
      # surface.
      refute Map.has_key?(row["attributes"], "cert_secret_ref")

      fresh = AccessDomain.get_by_id!(row["id"], authorize?: false)
      assert fresh.organization_id == org.id
      assert fresh.kind == :custom
      assert fresh.state == :pending
    end

    test "the domain lands canonical (trimmed + downcased), Certificate and all", %{conn: conn} do
      {user, _org} = paid_member!()
      pat = ApiPat.mint!(user, ["gateways:write"])

      # The mint fires for the canonicalized name's wildcard.
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["spec"]["dnsNames"] == ["*.apps.customer.com"]
        {:ok, %{status: 201, body: manifest}}
      end)

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

    test "a failed Certificate apply is a 5xx and NO row persists", %{conn: conn} do
      {user, _org} = paid_member!()
      pat = ApiPat.mint!(user, ["gateways:write"])

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 500, body: %{"message" => "apiserver down"}}}
      end)

      # The transactional rollback's best-effort cleanup (one delete,
      # 404 tolerated).
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200, body: %{}}} end)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-domains", %{
          "data" => %{
            "type" => "access_domain",
            "attributes" => %{"domain" => "failed.example.com"}
          }
        })

      assert %{"errors" => errors} = json_response(conn, 500)
      assert [%{"status" => "500"} | _rest] = errors

      # The transactional promise: no stranded half-registered row.
      refute domain_exists?("failed.example.com")
    end

    test "naming one of the caller's own orgs registers there (#408)", %{conn: conn} do
      # The named org is the org in play: ITS wallet carries the
      # entitlement (the ops suite's stance), so mark it paid.
      {user, _org} = paid_member!()
      pat = ApiPat.mint!(user, ["gateways:write"])

      {:ok, team} =
        Accounts.create_organization(user, %{
          name: "Domain Team",
          slug: "domain-team-#{System.unique_integer([:positive])}"
        })

      BillingFixtures.mark_paid!(team)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-domains", %{
          "data" => %{
            "type" => "access_domain",
            "attributes" => %{
              "domain" => "team.example.com",
              "organization_id" => team.id
            }
          }
        })

      assert %{"data" => %{"attributes" => %{"organization_id" => named}}} =
               json_response(conn, 201)

      assert named == team.id
    end

    test "a duplicate register is refused by name — no second mint", %{conn: conn} do
      {user, org} = paid_member!()
      custom_domain!(user, org, @domain_name)
      pat = ApiPat.mint!(user, ["gateways:write"])

      # EnsureRegistrable refuses in before_action — before any cluster
      # call, so no Certificate mint fires for the refused attempt.
      reject(Kubereq, :apply, 3)

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

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] == "is already registered"
    end

    test "a foreign organization_id is Forbidden — the wire names only the caller's own orgs",
         %{conn: conn} do
      # #408: the argument is member-fenced. The foreign org is paid so
      # membership is the only failing fence (the ops suite's stance).
      {user, _org} = paid_member!()
      {foreign, _foreign_owner} = BillingFixtures.grant_free_org!()
      BillingFixtures.mark_paid!(foreign)
      pat = ApiPat.mint!(user, ["gateways:write"])

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
      pat = ApiPat.mint!(user, ["gateways:write"])

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
      pat = ApiPat.mint!(user, ["gateways:write"])

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
      assert one["attributes"]["organization_id"] == org.id

      one_keys = Map.keys(one["attributes"])

      assert MapSet.new(one_keys) ==
               MapSet.new(["domain", "kind", "organization_id", "state"])

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
      pat = ApiPat.mint!(user, ["gateways:write"])

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
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/access-domains/#{domain.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == domain.id
      assert row["attributes"]["domain"] == @domain_name
      assert row["attributes"]["kind"] == "custom"
      assert row["attributes"]["state"] == "pending"
      assert row["attributes"]["organization_id"] == org.id
      refute Map.has_key?(row["attributes"], "cert_secret_ref")
    end

    test "the platform row is inspectable — kind platform", %{conn: conn} do
      {user, org} = paid_member!()
      domain = platform_domain!(org)
      pat = ApiPat.mint!(user, ["gateways:write"])

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
      pat = ApiPat.mint!(outsider, ["gateways:write"])

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
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-domains/#{domain.id}/resume", %{
          "data" => %{"type" => "access_domain", "id" => domain.id, "attributes" => %{}}
        })

      assert %{"data" => %{"attributes" => %{"state" => "verified"}}} = json_response(conn, 200)
    end

    test "a non-suspended row is a true no-op — no render, state unchanged", %{conn: conn} do
      {user, org} = paid_member!()
      pending = custom_domain!(user, org, @domain_name)

      # The wire can meet a :verified row (a stale provider cache
      # retrying after the observer re-verified it). The resume changes
      # nothing, so it must also re-render nothing — the render is a
      # full cluster-wide gather + ConfigMap write.
      {:ok, verified} = AccessDomain.mark_verified(pending, authorize?: false)
      pat = ApiPat.mint!(user, ["gateways:write"])

      reject(RenderAccessDNS, :call, 0)
      reject(RenderAccessDNS, :call, 1)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/access-domains/#{verified.id}/resume", %{
          "data" => %{"type" => "access_domain", "id" => verified.id, "attributes" => %{}}
        })

      assert %{"data" => %{"attributes" => %{"state" => "verified"}}} = json_response(conn, 200)
    end

    test "a drained wallet is Forbidden — the funded gate rides the wire", %{conn: conn} do
      {user, org} = paid_member!()
      domain = suspended_domain!(user, org)
      BillingFixtures.drain_wallet!(org)
      pat = ApiPat.mint!(user, ["gateways:write"])

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
      pat = ApiPat.mint!(outsider, ["gateways:write"])

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
    test "runs the full operation — tailnet unclaim, re-render, Certificate safe-delete", %{
      conn: conn
    } do
      {user, org} = paid_member!()
      domain = custom_domain!(user, org, @domain_name)
      pat = ApiPat.mint!(user, ["gateways:write"])

      # The claims' owner — the unclaim limb's subject (the ops suite's
      # stance: the gateway fixture's provision leg rides the stubs).
      stub(Tailscale, :provision_gateway, fn _gateway, _key ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      gateway = AccessFixtures.gateway!(org)

      claimed =
        Ash.update!(gateway, %{dns_claims: %{domain.domain => "10.43.0.20"}},
          action: :update_claims,
          authorize?: false
        )

      expect(Tailscale, :unclaim_domain, fn gw, name ->
        assert gw.id == claimed.id
        assert name == domain.domain
        :ok
      end)

      # The claims moved, so the Corefile re-renders before the result
      # returns (the derived-state stance).
      expect(RenderAccessDNS, :call, fn -> :ok end)

      expect(Kubereq, :delete, fn _req, ns, name ->
        config = Application.fetch_env!(:flux_vale, :access_domains)
        assert ns == config[:certificate_namespace]
        assert name == AccessDomain.certificate_name(domain)

        {:ok, %{status: 200}}
      end)

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      # Generic-action routes render the result flat (the instance
      # :delete shape) — no JSON:API envelope.
      assert body = json_response(conn, 200)
      assert body["id"] == domain.id
      refute Map.has_key?(body, "data")

      assert {:error, _not_found} = AccessDomain.get_by_id(domain.id, actor: user)

      # The claims entry went with the row.
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).dns_claims == %{}
    end

    test "a domain still serving hostnames is refused before any tailnet write", %{conn: conn} do
      {user, org} = paid_member!()
      domain = custom_domain!(user, org, @domain_name)
      hostname_instance!(user, domain)
      pat = ApiPat.mint!(user, ["gateways:write"])

      # P1-2's step (1): the pre-check precedes the tailnet — a refused
      # remove never disturbs the owner's tailnet.
      stub(Tailscale, :unclaim_domain, fn _gw, _name ->
        flunk("the hostname guard precedes any tailnet write")
      end)

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "still serves instance hostnames"

      assert {:ok, %AccessDomain{}} = AccessDomain.get_by_id(domain.id, actor: user)
    end

    test "the platform row is refused — it is load-bearing", %{conn: conn} do
      {user, org} = paid_member!()
      domain = platform_domain!(org)
      pat = ApiPat.mint!(user, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "not removable"

      assert {:ok, %AccessDomain{}} = AccessDomain.get_by_id(domain.id, actor: user)
    end

    test "an unclaim failure passes through — the honest 5xx, the row stands", %{conn: conn} do
      {user, org} = paid_member!()
      domain = custom_domain!(user, org, @domain_name)
      pat = ApiPat.mint!(user, ["gateways:write"])

      stub(Tailscale, :provision_gateway, fn _gateway, _key ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      gateway = AccessFixtures.gateway!(org)

      Ash.update!(gateway, %{dns_claims: %{domain.domain => "10.43.0.20"}},
        action: :update_claims,
        authorize?: false
      )

      # The unclaim limb fails the remove (the row stands, the retry
      # converges) — the wire carries the honest failure, not a guard
      # copy.
      stub(Tailscale, :unclaim_domain, fn _gw, _name -> {:error, :unauthorized} end)

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => [%{"status" => "500"}]} = json_response(conn, 500)

      assert {:ok, %AccessDomain{}} = AccessDomain.get_by_id(domain.id, actor: user)
    end

    test "a non-member's row is 404 — nothing removed, no cluster call", %{conn: conn} do
      {member, org} = paid_member!()
      domain = custom_domain!(member, org, @domain_name)
      {outsider, _outsider_org} = paid_member!()
      pat = ApiPat.mint!(outsider, ["gateways:write"])

      # The authorized re-read is the ownership fence: a non-member's
      # row never reaches the operation's limbs.
      stub(Kubereq, :delete, fn _req, _ns, _name ->
        flunk("no cluster call behind the ownership fence")
      end)

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)

      assert {:ok, %AccessDomain{}} = AccessDomain.get_by_id(domain.id, actor: member)
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Test precondition through the action, authorize?: false (the seeds
  # posture): the register action mints the Certificate too — the
  # setup's Kubereq stubs carry it. `user` is the org's member; the
  # tenancy change reads the org from the argument.
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

  # One hostname row on the domain — the hostnames_present refusal's
  # subject. The instance rides the real create action (the actor's
  # personal org — SetOrganizationFromActor); only the hostname row
  # matters here.
  defp hostname_instance!(user, domain) do
    InstanceFixtures.local_cluster!()
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    InstanceHostname.mint!(
      %{instance_id: instance.id, access_domain_id: domain.id, label: "app"},
      authorize?: false
    )

    instance
  end

  # Committed rows outside this transaction (strays from non-sandboxed
  # runs) are visible to the uniqueness probe — check existence, not
  # emptiness.
  defp domain_exists?(name) do
    AccessDomain
    |> Ash.Query.filter(domain == ^name)
    |> Ash.exists?(authorize?: false)
  end
end
