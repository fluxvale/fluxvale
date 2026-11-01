defmodule FluxValeWeb.AdminMountTest do
  @moduledoc false

  # The mounted surface (#288, ADR-0027 §2 Am. 2 — always mounted, the
  # key gate retired): the auth stack rides the TestInbox vocabulary,
  # the render carries the §3 domain split
  # (Infrastructure in, Identity out — asserted on the structured nav,
  # not raw-HTML substrings), one real action runs through AshAdmin (a
  # Cluster table read via the resource's primary read action), and the
  # on_mount socket gate re-checks what the router already checked — a
  # LiveView socket never re-enters the router.
  #
  # Honest posture, stated plainly (ADR-0027 Am. 1): AshAdmin's
  # `authorizing` toggle defaults OFF upstream and any admin can toggle
  # it, so actions on this surface effectively run authorize?: false —
  # the mount is a trusted-operator superuser surface and the §3 domain
  # opt-out (not the resource policies) is the data boundary. The route
  # gate + socket re-check decide who gets there.
  #
  # Sync-only: like the TestInbox gate tests, it mutates the app env.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster
  alias FluxValeWeb.AdminGate

  @admin_email "admin-mount-admin@fluxvale.com"
  @user_email "admin-mount-user@fluxvale.com"

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

  describe "route-level auth (the TestInbox vocabulary)" do
    test "anonymous bounces to /sign-in", %{conn: conn} do
      conn = get(conn, "/admin")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{conn: conn, admin: admin} do
      User.create!(@user_email, %{}, authorize?: false)
      user_pat = mint_pat!(@user_email, admin)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> user_pat)
        |> get("/admin")

      assert conn.status == 403
    end

    test "a platform-admin session renders AshAdmin with the §3 domain split", %{
      conn: conn,
      admin: admin
    } do
      conn = admin_session_conn(conn, admin)

      {:ok, view, _html} = live(conn, "/admin")

      # The sidebar's per-domain toggles are the structured nav; resource
      # links only render inside an expanded domain, so absence is
      # asserted on both shapes. The shown set is exactly the §3 opt-in.
      assert has_element?(view, "[phx-value-domain='Infrastructure']")
      assert has_element?(view, "[phx-value-domain='Billing']")
      refute has_element?(view, "[phx-value-domain='Identity']")
      refute has_element?(view, "a[href*='domain=Identity']")
      refute has_element?(view, "[phx-value-domain='Accounts']")
      refute has_element?(view, "a[href*='domain=Accounts']")
    end
  end

  describe "one real action path" do
    test "the Infrastructure/Cluster table reads rows through the resource's action", %{
      conn: conn,
      admin: admin
    } do
      # Precondition via the resource's own action (repo convention,
      # mirrors the seeds' authorize?: false bootstrap).
      Cluster.create(%{name: "admin-mount-cluster"}, authorize?: false)

      conn = admin_session_conn(conn, admin)

      assert {:ok, view, html} = live(conn, "/admin?domain=Infrastructure&resource=Cluster")

      assert has_element?(view, "table")
      assert html =~ "admin-mount-cluster"
    end
  end

  describe "the on_mount socket gate (AdminGate)" do
    test "a platform-admin session mounts", %{admin: admin} do
      session = admin_session(admin)

      assert {:cont, _socket} = AdminGate.on_mount(:ensure_admin, %{}, session, empty_socket())
    end

    test "a non-admin session redirects away (a bare halt raises in the mount lifecycle)", %{
      admin: _admin
    } do
      user = User.create!(@user_email, %{}, authorize?: false)

      # The session resolves, but not to a platform admin.
      assert {:halt, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/sign-in"}}}} =
               AdminGate.on_mount(:ensure_admin, %{}, user_session(user), empty_socket())
    end

    test "no session user redirects to sign-in", %{admin: _admin} do
      assert {:halt, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/sign-in"}}}} =
               AdminGate.on_mount(:ensure_admin, %{}, %{}, empty_socket())
    end

    test "the lifecycle contract, driven through live/2: a mount with no session user redirects (never raises)",
         %{
           conn: conn,
           admin_pat: pat
         } do
      # A bearer PAT satisfies the route pipeline (Authenticate is
      # bearer-first), but the socket carries the SESSION — and a
      # bearer never writes one. The on_mount re-check must answer the
      # denial with a redirect; the bare-halt shape would raise
      # ArgumentError inside LiveView's mount lifecycle here.
      conn = put_req_header(conn, "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin")
    end
  end

  # The mount is browser-shaped: the socket carries the token-backed
  # session (SessionHelpers' shape), not a bearer header — the on_mount
  # re-check resolves the actor from exactly this session.
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

  defp admin_session(admin) do
    user_session(admin)
  end

  # on_mount works on a bare socket struct; redirect/1 needs nothing
  # else populated.
  defp empty_socket do
    %Phoenix.LiveView.Socket{}
  end

  # mint_pat authorizes under the platform-admin policy (#23) — the admin
  # actor minting for the non-admin user above is the sanctioned shape
  # (mirrors test_inbox_route_test).
  defp mint_pat!(email, admin) do
    {:ok, token} = User.mint_pat(email, actor: admin)
    token
  end
end
