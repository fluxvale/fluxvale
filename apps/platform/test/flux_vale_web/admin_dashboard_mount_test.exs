defmodule FluxValeWeb.AdminDashboardMountTest do
  @moduledoc false

  # LiveDashboard on the admin surface (the LiveDashboard docs' prod
  # pattern, replacing the /dev-only mount): the same triple gate as
  # the AshAdmin mount (ADR-0027 §2 Am. 1's vocabulary — the closed
  # gate outranks credentials, the open gate bounces anonymous to
  # sign-in and 403s non-admins), PLUS the on_mount socket re-check:
  # the macro accepts on_mount and a LiveView socket never re-enters
  # the router, so a demoted admin's open dashboard tab cannot
  # outlive the gate — asserted by a denied mount, not just a denied
  # request.
  #
  # Sync-only: like the AdminMount tests, it mutates the app env.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User

  @admin_email "admin-dash-admin@fluxvale.com"
  @user_email "admin-dash-user@fluxvale.com"

  setup do
    original = Application.get_env(:flux_vale, :admin_mount_key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :admin_mount_key)
        value -> Application.put_env(:flux_vale, :admin_mount_key, value)
      end
    end)

    admin =
      case User.get_by_email(@admin_email, authorize?: false) do
        {:ok, existing} ->
          existing

        {:error, _not_found} ->
          User.create!(@admin_email, %{platform_role: :admin}, authorize?: false)
      end

    %{admin: admin, admin_pat: mint_pat!(@admin_email, admin)}
  end

  describe "the gate closed" do
    setup do
      Application.delete_env(:flux_vale, :admin_mount_key)
      :ok
    end

    test "404 even with valid admin credentials: the gate runs first and reveals nothing", %{
      conn: conn,
      admin_pat: pat
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/admin/dashboard")

      assert conn.status == 404
    end
  end

  describe "the gate open, route-level auth (the AdminMount vocabulary)" do
    setup do
      Application.put_env(:flux_vale, :admin_mount_key, "mount-open-literal")
      :ok
    end

    test "anonymous bounces to /sign-in", %{conn: conn} do
      conn = get(conn, "/admin/dashboard")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{conn: conn} do
      user = User.create!(@user_email, %{}, authorize?: false)

      conn =
        conn
        |> admin_session_conn(user)
        |> get("/admin/dashboard")

      assert conn.status == 403
    end

    test "a platform-admin session renders the LiveDashboard", %{conn: conn, admin: admin} do
      conn = admin_session_conn(conn, admin)

      # The index live-redirects to its Home page; mount a real page
      # directly (the metrics page — the surface this mount exists for).
      {:ok, _view, html} = live(conn, "/admin/dashboard/metrics")

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
    {:ok, token} = User.mint_pat(email, actor: admin)
    token
  end
end
