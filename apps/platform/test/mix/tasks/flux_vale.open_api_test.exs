defmodule Mix.Tasks.FluxVale.OpenApiTest do
  @moduledoc false

  # #360 slice 4 (ADR-0019 §2): the committed OpenAPI artifact is the
  # offline twin of GET /api/v1/open_api. This is the drift guard — a
  # route added without re-dumping fails mix ci here, not later in a
  # generated CLI client.

  use FluxValeWeb.ConnCase, async: true

  import ExUnit.CaptureIO

  alias FluxVale.Api.OpenApiDump
  alias FluxVale.TestSupport.ApiPat
  alias Mix.Tasks.FluxVale.OpenApi

  describe "the committed artifact" do
    test "equals the offline render byte-for-byte (the drift guard)" do
      artifact = File.read!(OpenApiDump.default_path())

      assert artifact == OpenApiDump.render(),
             "priv/open_api.json is stale — run `mix flux_vale.open_api` and commit it"
    end

    test "carries the S1 route families (spot check; the full table is route_inventory_test)" do
      paths =
        OpenApiDump.default_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("paths")

      # OpenAPI renders path params brace-style ({id}, not :id).
      assert paths["/api/v1/me"]["get"]
      assert paths["/api/v1/instances"]["get"]
      assert paths["/api/v1/organizations/{organization_id}/wallet/runway"]["get"]
      assert paths["/api/v1/instances/{id}/deploy"]["patch"]
      assert paths["/api/v1/instances/{id}"]["delete"]
    end

    test "equals what the server serves at GET /api/v1/open_api", %{conn: conn} do
      # No VM warming needed: the /api/v1 scope plug pins the render's
      # module loads on the request itself, so the served document is
      # the full render — cold boot or warmed suite alike.
      {_user, pat} = ApiPat.member!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/api/v1/open_api")

      assert conn.status == 200

      served = Jason.decode!(conn.resp_body)

      artifact =
        OpenApiDump.default_path()
        |> File.read!()
        |> Jason.decode!()

      # `servers` is the one permitted difference, by construction: the
      # served document fills it from the Phoenix endpoint's runtime
      # config (host/port per environment); the offline render leaves
      # it empty so the artifact bakes no deployment URL into the
      # contract. Everything else must be identical.
      assert Map.drop(served, ["servers"]) == Map.drop(artifact, ["servers"])
    end
  end

  describe "mix flux_vale.open_api" do
    test "--check on the committed artifact reports up to date" do
      output = capture_io(fn -> OpenApi.run(["--check"]) end)

      assert output =~ "open_api.json up to date"
    end

    test "writes the render to an explicit path" do
      path = tmp_path()

      output = capture_io(fn -> OpenApi.run([path]) end)

      assert output =~ "wrote #{path}"
      assert File.read!(path) == OpenApiDump.render()
    end

    test "--check exits 1 on a stale artifact" do
      path = tmp_path()
      File.write!(path, "{\n  \"stale\": true\n}\n")

      output =
        capture_io(:stderr, fn ->
          assert catch_exit(OpenApi.run(["--check", path])) == {:shutdown, 1}
        end)

      assert output =~ "is stale — run `mix flux_vale.open_api` and commit it"
    end

    test "--check exits 1 when the artifact is missing" do
      path = tmp_path()

      output =
        capture_io(:stderr, fn ->
          assert catch_exit(OpenApi.run(["--check", path])) == {:shutdown, 1}
        end)

      assert output =~ "cannot read #{path}"
    end

    test "an unknown flag exits 1 instead of silently writing" do
      output =
        capture_io(:stderr, fn ->
          assert catch_exit(OpenApi.run(["--chek"])) == {:shutdown, 1}
        end)

      assert output =~ "unknown flag --chek"
    end

    test "a second positional argument exits 1 instead of silently dropping it" do
      output =
        capture_io(:stderr, fn ->
          assert catch_exit(OpenApi.run(["a.json", "b.json"])) == {:shutdown, 1}
        end)

      assert output =~ "unexpected extra argument"
    end
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "open_api_#{System.unique_integer()}.json")
  end
end
