defmodule FluxValeWeb.AdminHomeLiveTest do
  @moduledoc false

  # The custom operator console home (ADR-0027 Am. 3, #501): the /admin
  # landing renders the surface map — three unbuilt surfaces, each
  # honestly badged, plus the live catalog, people, and wallets cards
  # (this lane's slices) and the two generated tools on their demoted
  # debug subpaths. No data queries, so one admin mount covers the whole
  # module. The gate arms here are the route-level ones (the anonymous
  # 302, the non-admin 403); the on_mount socket re-check is the shared
  # AdminGate hook, already covered by admin_mount_test — this route
  # adds no hook of its own.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User

  @admin_email "admin-home-admin@fluxvale.com"
  @user_email "admin-home-user@fluxvale.com"

  @unbuilt_surface_testids ~w(
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
      for testid <- @unbuilt_surface_testids do
        assert has_element?(view, "[data-testid='#{testid}']", "Coming in this lane")
      end

      # The catalog, people, and wallets surfaces are live (this lane's
      # slices): each card is a link into its surface, with the Open
      # affordance in the badge's slot, no longer badged.
      assert has_element?(view, "[data-testid='admin-surface-catalog'][href='/admin/catalog']")
      assert has_element?(view, "[data-testid='admin-surface-catalog']", "Open")

      assert has_element?(view, "[data-testid='admin-surface-people'][href='/admin/people']")
      assert has_element?(view, "[data-testid='admin-surface-people']", "Open")

      assert has_element?(view, "[data-testid='admin-surface-wallets'][href='/admin/billing']")
      assert has_element?(view, "[data-testid='admin-surface-wallets']", "Open")

      refute has_element?(view, "[data-testid='admin-surface-catalog']", "Coming in this lane")
      refute has_element?(view, "[data-testid='admin-surface-people']", "Coming in this lane")
      refute has_element?(view, "[data-testid='admin-surface-wallets']", "Coming in this lane")

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
