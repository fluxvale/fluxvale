defmodule FluxValeWeb.Api.InstanceHostnameRouteTest do
  @moduledoc false

  # S6 (#751): the custom-address wire contract — POST/GET under an
  # instance, DELETE by hostname id. The operations own ownership and
  # the domain/state guards; the routes carry the instances scope.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  setup do
    verify_on_exit!()

    stub(Kubereq, :attach, fn req, _opts -> req end)

    stub(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    InstanceFixtures.local_cluster!()

    user = elem(ApiPat.member!(), 0)
    pat = ApiPat.mint!(user, ["instances:write"])
    instance = instance!(user)

    {:ok, user: user, pat: pat, instance: instance}
  end

  describe "POST /api/v1/instances/:instance_id/hostnames" do
    test "mints a custom address under a verified domain", %{
      conn: conn,
      pat: pat,
      instance: instance
    } do
      domain = verified_domain!(instance)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => domain.id, "label" => "git"}
          }
        })

      assert %{"data" => row} = json_response(conn, 201)
      assert row["type"] == "instance_hostname"
      assert row["attributes"]["label"] == "git"
      assert row["attributes"]["instance_id"] == instance.id
      assert row["attributes"]["access_domain_id"] == domain.id

      attr_keys = Map.keys(row["attributes"])

      assert MapSet.new(attr_keys) ==
               MapSet.new(["label", "instance_id", "access_domain_id", "created_at"])

      assert hostname_exists?(instance.id, "git")
    end

    test "a platform domain is refused with the operation's words", %{
      conn: conn,
      pat: pat,
      instance: instance
    } do
      platform =
        AccessDomain
        |> Ash.Query.filter(organization_id == ^instance.organization_id and kind == :platform)
        |> Ash.read_one!(authorize?: false)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => platform.id, "label" => "git"}
          }
        })

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "only a custom domain"
    end

    test "an unverified domain is refused with the operation's words", %{
      conn: conn,
      pat: pat,
      instance: instance
    } do
      domain = custom_domain!(instance)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => domain.id, "label" => "git"}
          }
        })

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "verify the domain"
    end

    test "a foreign org's domain is a not-found (the domain read fence)", %{
      conn: conn,
      pat: pat,
      instance: instance
    } do
      {other_org, _other_owner} = BillingFixtures.grant_free_org!()
      domain = verified_domain!(other_org.id)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => domain.id, "label" => "git"}
          }
        })

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end

    test "a dual-member actor cannot mint across orgs — the operation fence bites", %{
      conn: conn,
      user: user,
      instance: instance
    } do
      {other_org, _other_owner} = BillingFixtures.grant_free_org!()

      Membership.create!(
        %{organization_id: other_org.id, user_id: user.id, role: :member},
        authorize?: false
      )

      domain = verified_domain!(other_org.id)

      conn =
        conn
        |> auth(ApiPat.mint!(user, ["instances:write"]))
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => domain.id, "label" => "git"}
          }
        })

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "different organization"
    end

    test "a foreign instance is 404 before any row lands", %{
      conn: conn,
      instance: instance
    } do
      domain = verified_domain!(instance)
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()
      other_pat = ApiPat.mint!(other_owner, ["instances:write"])

      conn =
        conn
        |> auth(other_pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => domain.id, "label" => "git"}
          }
        })

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
      refute hostname_exists?(instance.id, "git")
    end

    test "a duplicate label is refused by the unique identity", %{
      conn: conn,
      pat: pat,
      instance: instance
    } do
      domain = verified_domain!(instance)
      _row = custom_hostname!(instance, domain, "git")

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => domain.id, "label" => "git"}
          }
        })

      assert %{"errors" => [_error | _rest]} = json_response(conn, conn.status)
      assert conn.status in [400, 409]
    end

    test "instances:read alone cannot mint", %{conn: conn, user: user, instance: instance} do
      domain = verified_domain!(instance)
      read_pat = ApiPat.mint!(user, ["instances:read"])

      conn =
        conn
        |> auth(read_pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/hostnames", %{
          "data" => %{
            "type" => "instance_hostname",
            "attributes" => %{"access_domain_id" => domain.id, "label" => "git"}
          }
        })

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)
    end
  end

  describe "GET /api/v1/instances/:instance_id/hostnames" do
    test "lists the instance's addresses, fields pinned", %{
      conn: conn,
      pat: pat,
      instance: instance
    } do
      domain = verified_domain!(instance)
      custom = custom_hostname!(instance, domain, "git")

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}/hostnames")

      assert %{"data" => rows} = json_response(conn, 200)
      assert length(rows) == 2

      custom_row = Enum.find(rows, &(&1["id"] == custom.id))
      assert custom_row["attributes"]["label"] == "git"
      assert custom_row["attributes"]["access_domain_id"] == domain.id
    end

    test "another instance's addresses never leak", %{
      conn: conn,
      pat: pat,
      user: user,
      instance: instance
    } do
      domain = verified_domain!(instance)
      _custom = custom_hostname!(instance, domain, "git")
      other_instance = instance!(user)

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{other_instance.id}/hostnames")

      assert %{"data" => rows} = json_response(conn, 200)
      labels = Enum.map(rows, & &1["attributes"]["label"])
      refute "git" in labels
    end

    test "a foreign instance lists empty — index semantics, never a leak", %{
      conn: conn,
      instance: instance
    } do
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()
      other_pat = ApiPat.mint!(other_owner, ["instances:read"])

      conn =
        conn
        |> auth(other_pat)
        |> get("/api/v1/instances/#{instance.id}/hostnames")

      # The read policy filters the rows, so a mistyped/foreign instance
      # reads as "no addresses" (the AccessDomain list-for-org stance),
      # not a distinguishable 404.
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/v1/instance-hostnames/:id" do
    test "removes a custom address", %{conn: conn, pat: pat, instance: instance} do
      domain = verified_domain!(instance)
      hostname = custom_hostname!(instance, domain, "git")

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/instance-hostnames/#{hostname.id}")

      assert body = json_response(conn, 200)
      assert body["id"] == hostname.id
      refute hostname_exists?(instance.id, "git")
    end

    test "the default platform address is refused", %{conn: conn, pat: pat, instance: instance} do
      default =
        InstanceHostname
        |> Ash.Query.filter(instance_id == ^instance.id and label == ^instance.slug)
        |> Ash.read_one!(authorize?: false)

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/instance-hostnames/#{default.id}")

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "default address is not removable"
      assert hostname_exists?(instance.id, instance.slug)
    end

    test "a foreign address is 404", %{conn: conn, instance: instance} do
      domain = verified_domain!(instance)
      hostname = custom_hostname!(instance, domain, "git")
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()
      other_pat = ApiPat.mint!(other_owner, ["instances:write"])

      conn =
        conn
        |> auth(other_pat)
        |> delete("/api/v1/instance-hostnames/#{hostname.id}")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
      assert hostname_exists?(instance.id, "git")
    end

    test "instances:read alone cannot remove", %{conn: conn, user: user, instance: instance} do
      domain = verified_domain!(instance)
      hostname = custom_hostname!(instance, domain, "git")
      read_pat = ApiPat.mint!(user, ["instances:read"])

      conn =
        conn
        |> auth(read_pat)
        |> delete("/api/v1/instance-hostnames/#{hostname.id}")

      assert %{"errors" => [%{"status" => "403"}]} = json_response(conn, 403)
      assert hostname_exists?(instance.id, "git")
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp instance!(user) do
    version = InstanceFixtures.app_version!()

    Instance.create!(
      %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
      actor: user
    )
  end

  defp custom_domain!(%Instance{} = instance) do
    custom_domain!(instance.organization_id)
  end

  defp custom_domain!(organization_id) do
    name = "apps-#{System.unique_integer([:positive])}.customer.test"

    AccessDomain.register!(
      %{domain: name, organization_id: organization_id},
      actor: org_actor!(organization_id),
      authorize?: false
    )
  end

  # The register action's org change needs an actor even with a named
  # org (the fixture's bootstrap posture); the owner is the honest one.
  defp org_actor!(organization_id) do
    Membership
    |> Ash.Query.filter(organization_id == ^organization_id and role == :owner)
    |> Ash.read_one!(authorize?: false)
  end

  defp verified_domain!(%Instance{} = instance), do: verified_domain!(instance.organization_id)

  defp verified_domain!(organization_id) do
    domain = custom_domain!(organization_id)
    {:ok, verified} = AccessDomain.mark_verified(domain, authorize?: false)
    verified
  end

  defp custom_hostname!(instance, domain, label) do
    InstanceHostname.mint!(
      %{instance_id: instance.id, access_domain_id: domain.id, label: label},
      authorize?: false
    )
  end

  defp hostname_exists?(instance_id, label) do
    InstanceHostname
    |> Ash.Query.filter(instance_id == ^instance_id and label == ^label)
    |> Ash.exists?(authorize?: false)
  end
end
