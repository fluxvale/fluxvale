defmodule FluxValeWeb.HealthControllerTest do
  # async: false — the sha-formatting test mutates the global :build_sha app
  # env (read via FluxVale.Build.version/0); it must not race sibling modules
  use FluxValeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias FluxVale.TestSupport.InstanceFixtures

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
    test "ok when the database answers and boot invariants hold", %{conn: conn} do
      # #175: readiness gates on required reference data too — the
      # fixtures build the full invariant set (app version chain covers
      # pricing + catalog; the cluster row is the third).
      InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      conn = get(conn, ~p"/health/ready")

      assert %{"status" => "ok", "version" => _version} = json_response(conn, 200)
    end

    test "503 + an error log naming the invariant when reference data is missing", %{
      conn: conn
    } do
      # Oct 20's shape: the DB answers, the env is half-seeded. Silence
      # here is what let prod read "healthy" while every deploy failed.
      log =
        capture_log(fn ->
          conn = get(conn, ~p"/health/ready")

          assert %{"status" => "unhealthy"} = json_response(conn, 503)
        end)

      assert log =~ "readiness invariants failing"
      assert log =~ "clusters: 0 rows"
      assert log =~ "pricing: no rows"
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
