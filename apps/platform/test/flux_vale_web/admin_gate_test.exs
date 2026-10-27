defmodule FluxValeWeb.AdminGateTest do
  @moduledoc false

  # The AshAdmin mount gate (#288, ADR-0027 §2): default-denied — /admin
  # 404s while ADMIN_MOUNT_KEY is unset (prod never sets it), and the
  # answer fails closed for every plausible "off" shape; flipping the
  # key mounts the route, and the anonymous bounce is the route-level
  # auth arm. The authenticated render + a real action live in
  # admin_mount_test (they need the sandbox).
  #
  # This file avoids test/support (ConnCase compiles :test-only) so it
  # doubles as the release-mode proof — `MIX_ENV=prod mix test
  # test/flux_vale_web/admin_gate_test.exs` (a throwaway DATABASE_URL
  # plus the :prod boot envs; the app boots Repo/Oban, but nothing here
  # asserts against the DB) runs both arms against the router every
  # release compiles. CI runs the same command as its own step.
  # Sync-only: it mutates the app env.

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint FluxValeWeb.Endpoint

  setup do
    original = Application.get_env(:flux_vale, :admin_mount_key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :admin_mount_key)
        value -> Application.put_env(:flux_vale, :admin_mount_key, value)
      end
    end)

    :ok
  end

  describe "the gate closed (default-denied, fail-closed)" do
    setup do
      Application.delete_env(:flux_vale, :admin_mount_key)
      :ok
    end

    test "GET /admin is a 404" do
      conn = get(https_conn(), "/admin")

      assert conn.status == 404
    end

    test "deep admin paths 404 too — the whole surface, not just the root" do
      conn = get(https_conn(), "/admin/Infrastructure/Cluster")

      assert conn.status == 404
    end

    test "an empty secret value stays off (the classic empty-Secret shape)" do
      Application.put_env(:flux_vale, :admin_mount_key, "")

      conn = get(https_conn(), "/admin")

      assert conn.status == 404
    end

    test "off-intent literals stay off — writing false to disable must never enable" do
      for literal <- [" ", "false", "0", "off", "no"] do
        Application.put_env(:flux_vale, :admin_mount_key, literal)

        conn = get(https_conn(), "/admin")

        assert conn.status == 404
      end
    end

    test "the closed 404 runs before content negotiation — no Accept-header oracle" do
      conn =
        https_conn()
        |> put_req_header("accept", "application/json")
        |> get("/admin")

      assert conn.status == 404
    end
  end

  describe "the gate open" do
    setup do
      Application.put_env(:flux_vale, :admin_mount_key, "gate-open-literal")
      :ok
    end

    test "/admin is mounted — anonymous bounces to sign-in (route-level auth)" do
      conn = get(https_conn(), "/admin")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end
  end

  # Under MIX_ENV=prod the endpoint enforces force_ssl (prod.exs, on
  # x-forwarded-proto) — the prod-mode run of this file would otherwise
  # 301 before the router is ever reached. The header is what the edge
  # terminator (Traefik) sets on every real request; under :test the
  # plug isn't compiled and the header is inert.
  defp https_conn do
    put_req_header(build_conn(), "x-forwarded-proto", "https")
  end
end
