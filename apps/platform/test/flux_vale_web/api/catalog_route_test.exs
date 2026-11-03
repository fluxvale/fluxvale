defmodule FluxValeWeb.Api.CatalogRouteTest do
  @moduledoc false

  # #360: the catalog family's wire contract — the browse list, the
  # slug-keyed detail, and the version reads. The read policy is the
  # public-browse one; the /api/v1 pipeline still requires a token.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  setup do
    version = InstanceFixtures.app_version!(app_slug: "forgejo")
    pat = elem(ApiPat.member!(["catalog:read"]), 1)
    %{version: version, pat: pat}
  end

  describe "GET /api/v1/apps" do
    test "lists the catalog sorted by name", %{conn: conn, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps")

      assert %{"data" => rows} = json_response(conn, 200)
      assert [%{"type" => "app"} | _rest] = rows

      names = Enum.map(rows, & &1["attributes"]["name"])
      assert names == Enum.sort(names)

      row = Enum.find(rows, &(&1["attributes"]["slug"] == "forgejo"))
      assert row["attributes"]["file_access"] == false
    end
  end

  describe "GET /api/v1/apps/:slug" do
    test "returns the app by slug", %{conn: conn, version: version, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/forgejo")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["type"] == "app"
      assert row["id"] == version.app_id
      assert row["attributes"]["slug"] == "forgejo"
      assert row["attributes"]["name"]
    end

    test "an unknown slug is a 404", %{conn: conn, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/no-such-app")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/apps/:app_id/versions" do
    test "lists the app's versions newest first", %{conn: conn, version: version, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{version.app_id}/versions")

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["type"] == "app_version"
      assert row["id"] == version.id
      assert row["attributes"]["image"] == "registry.example.com/app:1.0"
      assert row["attributes"]["port"] == 3000
    end
  end

  describe "GET /api/v1/app-versions/:id" do
    test "returns the version by id", %{conn: conn, version: version, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/app-versions/#{version.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == version.id
      assert row["attributes"]["version"] == version.version
      assert row["attributes"]["default_memory_mb"] == 256
    end
  end
end
