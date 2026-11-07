defmodule FluxValeWeb.AdminHomeLiveTest do
  @moduledoc false

  # The custom operator console home (ADR-0027 Am. 3, #501): the /admin
  # landing renders a STATIC surface map — six unbuilt surfaces, each
  # honestly badged, plus the two generated tools on their demoted
  # debug subpaths. No data queries, so one admin mount covers the
  # whole module. The gate arms here are the route-level ones (the
  # anonymous 302, the non-admin 403); the on_mount socket re-check is
  # the shared AdminGate hook, already covered by admin_mount_test —
  # this route adds no hook of its own.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User

  @admin_email "admin-home-admin@fluxvale.com"
  @user_email "admin-home-user@fluxvale.com"

  @surface_testids ~w(
    admin-surface-people
    admin-surface-catalog
    admin-surface-wallets
    admin-surface-feedback
    admin-surface-orgs
    admin-surface-gateways
  )

  setup do
    admin =
      case User.get_by_email(@admin_email, authorize?: false) do
        {:ok, existing} ->
          existing

        {:error, _not_found} ->
          User.create!(@admin_email, %{platform_role: :admin}, authorize?: false)
      end

    %{admin: admin}
  end

  describe "the operator console home" do
    test "a platform-admin session renders the static surface map", %{conn: conn, admin: admin} do
      conn = admin_session_conn(conn, admin)

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, "[data-testid='admin-home']")

      # Every unbuilt surface renders a card, and every card is
      # honestly badged — nothing on the map fakes being live.
      for testid <- @surface_testids do
        assert has_element?(view, "[data-testid='#{testid}']", "Coming in this lane")
      end

      # The generated tools link from the deep debugging section at
      # their demoted subpaths.
      assert has_element?(view, "[data-testid='admin-fallback-ash'][href='/admin/ash']")

      assert has_element?(
               view,
               "[data-testid='admin-fallback-dashboard'][href='/admin/debug/dashboard']"
             )
    end

    test "a signed-in non-admin gets a bare 403 (route-level gate)", %{conn: conn} do
      user = User.create!(@user_email, %{}, authorize?: false)

      conn =
        conn
        |> admin_session_conn(user)
        |> get("/admin")

      assert conn.status == 403
    end

    test "anonymous bounces to /sign-in (route-level gate)", %{conn: conn} do
      conn = get(conn, "/admin")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end
  end

  # The home is browser-shaped: the socket carries the token-backed
  # session, the same shape every admin suite drives.
  defp admin_session_conn(conn, user) do
    {:ok, token, _claims} = Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end
end
