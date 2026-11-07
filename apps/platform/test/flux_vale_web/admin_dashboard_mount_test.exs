defmodule FluxValeWeb.AdminDashboardMountTest do
  @moduledoc false

  # LiveDashboard on the admin surface (the LiveDashboard docs' prod
  # pattern, replacing the /dev-only mount): the same auth stack as
  # the AshAdmin mount (anonymous bounces to sign-in, non-admins get a
  # 403), PLUS the on_mount socket re-check:
  # the macro accepts on_mount and a LiveView socket never re-enters
  # the router, so a demoted admin's open dashboard tab cannot
  # outlive the gate — asserted by a denied mount, not just a denied
  # request.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User

  @admin_email "admin-dash-admin@fluxvale.com"
  @user_email "admin-dash-user@fluxvale.com"

  # #360: fvpat_ tokens with the full S1 grant set — the surface under
  # test is admin-gated (outside /api/v1), so the scopes are unused
  # here; they ride the helper to future-proof the suites that share
  # its shape.
  @s1_scopes [
    "instances:read",
    "instances:write",
    "backups:read",
    "backups:write",
    "gateways:read",
    "gateways:write",
    "wallet:read",
    "catalog:read"
  ]

  # No app-env gate to sync (Am. 2): the surface is always mounted.
  setup do
    admin =
      case User.get_by_email(@admin_email, authorize?: false) do
        {:ok, existing} ->
          existing

        {:error, _not_found} ->
          User.create!(@admin_email, %{platform_role: :admin}, authorize?: false)
      end

    %{admin: admin, admin_pat: mint_pat!(@admin_email, admin)}
  end

  describe "route-level auth (the AdminMount vocabulary)" do
    test "anonymous bounces to /sign-in", %{conn: conn} do
      conn = get(conn, "/admin/debug/dashboard")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{conn: conn} do
      user = User.create!(@user_email, %{}, authorize?: false)

      conn =
        conn
        |> admin_session_conn(user)
        |> get("/admin/debug/dashboard")

      assert conn.status == 403
    end

    test "a platform-admin session renders the LiveDashboard", %{conn: conn, admin: admin} do
      conn = admin_session_conn(conn, admin)

      # The index live-redirects to Home, and pages redirect again to
      # pin their nav param — follow_redirect lands wherever the
      # dashboard settles (the surface this mount exists for).
      {:ok, _view, html} =
        conn
        |> live("/admin/debug/dashboard")
        |> follow_redirect(conn)

      assert html =~ "Metrics"
    end

    test "the on_mount socket re-check denies a non-admin's mount" do
      user = User.create!(@user_email, %{}, authorize?: false)

      # The route gate already 403s a non-admin's HTTP request (asserted
      # above), so the socket arm is driven the way the AdminMount suite
      # drives the same shared hook: directly, with the session a live
      # tab would carry. The dashboard's live mount attaches this exact
      # hook (the macro's on_mount option), so this is the open-tab-
      # after-demotion shape.
      assert {:halt, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/sign-in"}}}} =
               FluxValeWeb.AdminGate.on_mount(
                 :ensure_admin,
                 %{},
                 user_session(user),
                 %Phoenix.LiveView.Socket{}
               )
    end
  end

  defp admin_session_conn(conn, user) do
    {:ok, token, _claims} = Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp user_session(user) do
    {:ok, token, _claims} = Jwt.token_for_user(user)
    %{"user_token" => token}
  end

  defp mint_pat!(email, admin) do
    {:ok, user} = User.get_by_email(email, authorize?: false)

    {:ok, %{token: token}} =
      FluxVale.Identity.mint_pat(admin, %{
        user_id: user.id,
        name: "mount test",
        scopes: @s1_scopes
      })

    token
  end
end
