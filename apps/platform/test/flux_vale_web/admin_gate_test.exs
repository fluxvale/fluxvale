defmodule FluxValeWeb.AdminGateTest do
  @moduledoc false

  # The admin surface's route posture (#288, ADR-0027 §2 Am. 2):
  # ALWAYS MOUNTED — the runtime ADMIN_MOUNT_KEY gate is retired, and
  # the platform-admin auth is the gate. The anonymous bounce is the
  # route-level auth arm; the authenticated render + a real action
  # live in admin_mount_test (they need the sandbox).
  #
  # This file avoids test/support (ConnCase compiles :test-only) so it
  # doubles as the release-mode proof — `MIX_ENV=prod mix test
  # test/flux_vale_web/admin_gate_test.exs` (a throwaway DATABASE_URL
  # plus the :prod boot envs; the app boots Repo/Oban, but nothing here
  # asserts against the DB) runs the arms against the router every
  # release compiles. CI runs the same command as its own step.
  # No app-env mutation left to sync: the posture is compile-fixed.

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint FluxValeWeb.Endpoint

  describe "always mounted, auth-gated (Am. 2)" do
    test "/admin is mounted — anonymous bounces to sign-in (route-level auth)" do
      conn = get(https_conn(), "/admin")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "deep admin paths bounce too — the auth covers the whole surface" do
      conn = get(https_conn(), "/admin/Infrastructure/Cluster")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "the dashboard mount is alive at its path — anonymous bounces, never 404s" do
      conn = get(https_conn(), "/admin/dashboard")

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
