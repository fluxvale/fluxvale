defmodule FluxValeWeb.HealthControllerTest do
  # async: false — the sha-formatting test mutates the global :build_sha app
  # env (read via FluxVale.Build.version/0); it must not race sibling modules
  use FluxValeWeb.ConnCase, async: false

  describe "GET /health (liveness)" do
    test "reports ok with the build version, dependency-free", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert %{"status" => "ok", "version" => version} = json_response(conn, 200)
      assert is_binary(version)
    end

    test "versions as sha-<sha> when BUILD_SHA is set", %{conn: conn} do
      previous = Application.get_env(:flux_vale, :build_sha)
      Application.put_env(:flux_vale, :build_sha, "abc1234")

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:flux_vale, :build_sha)
          value -> Application.put_env(:flux_vale, :build_sha, value)
        end
      end)

      conn = get(conn, ~p"/health")
      assert %{"version" => "sha-abc1234"} = json_response(conn, 200)
    end
  end

  describe "GET /health/ready (readiness)" do
    test "ok when the database answers", %{conn: conn} do
      conn = get(conn, ~p"/health/ready")

      assert %{"status" => "ok", "version" => _} = json_response(conn, 200)
    end

    test "liveness stays 200 even when the database connection is broken", %{conn: conn} do
      # The mirror of readiness: kill this test's backend, then prove /health
      # answers without consulting the database. (The true 503 path can't be
      # simulated against a live Postgres — DBConnection reconnects by design —
      # it is validated for real in #7 by killing the CNPG pod in k3d.)
      _ = FluxVale.Repo.query("SELECT pg_terminate_backend(pg_backend_pid())")

      conn = get(conn, ~p"/health")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
