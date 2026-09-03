defmodule FluxValeWeb.HealthControllerTest do
  # async: false — the sha-formatting test mutates the global :build_sha app
  # env (read via FluxVale.Build.version/0); it must not race sibling modules
  use FluxValeWeb.ConnCase, async: false

  describe "GET /health (liveness)" do
    test "reports ok with version dev when BUILD_SHA is unset", %{conn: conn} do
      stub_build_sha(nil)

      conn = get(conn, ~p"/health")

      assert %{"status" => "ok", "version" => "dev"} = json_response(conn, 200)
    end

    test "versions as sha-<sha> when BUILD_SHA is set", %{conn: conn} do
      stub_build_sha("abc1234")

      conn = get(conn, ~p"/health")
      assert %{"version" => "sha-abc1234"} = json_response(conn, 200)
    end
  end

  describe "GET /health/ready (readiness)" do
    test "ok when the database answers", %{conn: conn} do
      conn = get(conn, ~p"/health/ready")

      assert %{"status" => "ok", "version" => _version} = json_response(conn, 200)
    end

    test "liveness stays 200 even when the database connection is broken", %{conn: conn} do
      # The mirror of readiness: kill this test's backend, then prove /health
      # answers without consulting the database. (The true 503 path can't be
      # simulated against a live Postgres — DBConnection reconnects by design —
      # it is validated for real in #7 by killing the CNPG pod in k3d.)
      _terminated = FluxVale.Repo.query("SELECT pg_terminate_backend(pg_backend_pid())")

      conn = get(conn, ~p"/health")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end

  # Sets (or clears, when nil) :build_sha for the current test and restores
  # whatever came before — ambient BUILD_SHA from the environment included —
  # so assertions own their preconditions.
  defp stub_build_sha(value) do
    previous = Application.get_env(:flux_vale, :build_sha)

    if value do
      Application.put_env(:flux_vale, :build_sha, value)
    else
      Application.delete_env(:flux_vale, :build_sha)
    end

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:flux_vale, :build_sha)
        restored -> Application.put_env(:flux_vale, :build_sha, restored)
      end
    end)
  end
end
