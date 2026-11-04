defmodule FluxValeWeb.Api.PaywallRouteTest do
  @moduledoc false

  # #360's Done-when proofs: the money gates bite API callers exactly
  # as they bite the LiveViews. A funded-but-never-paid org (the $3
  # welcome credit) reads its instances but cannot mint backup
  # settings or gateways; a zero-balance org cannot deploy. These are
  # the POLICY refusals (403) — a scope-gate 403 from the PAT slice
  # would be a different failure and must never satisfy these.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp instance_for!(user) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    InstanceFixtures.instance!(version, user)
  end

  describe "the funded-but-never-paid org (welcome credits never qualify)" do
    test "reads its instances (200) but the paid-once gates refuse the writes (403)", %{
      conn: _conn
    } do
      # ApiPat.member!'s org is JIT-provisioned: 300¢ welcome credit,
      # zero purchases — funded, never paid.
      {user, _pat} = ApiPat.member!()
      pat = ApiPat.mint!(user.email, ["instances:write", "backups:write", "gateways:write"])
      instance = instance_for!(user)

      list =
        build_conn()
        |> auth(pat)
        |> get("/api/v1/instances")

      assert %{"data" => [_row]} = json_response(list, 200)

      setting =
        build_conn()
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/backup-setting", %{
          "data" => %{
            "type" => "backup_setting",
            "attributes" => %{
              "endpoint" => "https://account.r2.cloudflarestorage.com",
              "bucket" => "fluxvale-kavita",
              "access_key_id" => "AKIAIOSFODNN7EXAMPLE"
            }
          }
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(setting, 403)

      gateway =
        build_conn()
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{"tailnet_domain" => "example.ts.net", "auth_key" => "tskey-test"}
          }
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(gateway, 403)
    end
  end

  describe "the zero-balance org" do
    test "deploy is refused by the funded gate (403)", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      org = BillingFixtures.mark_user_paid!(user)

      # The row must exist BEFORE the drain — creation itself needs a
      # funded wallet; the zero-balance proof is about deploy.
      instance = instance_for!(user)
      :ok = BillingFixtures.drain_wallet!(org)

      pat = ApiPat.mint!(user.email, ["instances:write", "backups:write", "gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/instances/#{instance.id}/deploy", %{
          "data" => %{"type" => "instance", "id" => instance.id, "attributes" => %{}}
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(conn, 403)
    end

    # #362: creation joined the wire — the same gate, proven at the new
    # front door (the zero-balance proof is about CREATE here).
    test "create is refused by the funded gate (403)", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      org = BillingFixtures.mark_user_paid!(user)
      :ok = BillingFixtures.drain_wallet!(org)

      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      pat = ApiPat.mint!(user.email, ["instances:write", "backups:write", "gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances", %{
          "data" => %{
            "type" => "instance",
            "attributes" => %{"name" => "Zero Balance", "app_version_id" => version.id}
          }
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(conn, 403)
    end
  end
end
