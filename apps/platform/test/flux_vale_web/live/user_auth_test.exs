defmodule FluxValeWeb.UserAuthTest do
  @moduledoc false

  # The :authenticated live_session's on_mount gate (#74): session
  # resolution with revocation + AccessRule parity, then the redirect.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.UserAuth

  test "a valid session mounts and assigns the actor", %{conn: conn} do
    {_user, conn} = SessionHelpers.user_with_session(conn)

    {:ok, view, html} = live(conn, ~p"/apps")

    assert has_element?(view, "h1", "Catalog")
    assert html =~ "Sign out"
  end

  test "no session redirects to /sign-in with the request path back", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{})

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/apps")
    # #462: the gate's redirect carries the return path — sign-in lands
    # the visitor back on the gated page they hit
    assert to == "/sign-in?return_to=%2Fapps"
  end

  test "the gate's return path preserves the query string", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{})

    assert {:error, {:redirect, %{to: to}}} = live(conn, "/invitations/accept?token=abc123")
    assert to == "/sign-in?return_to=%2Finvitations%2Faccept%3Ftoken%3Dabc123"
  end

  test "a revoked session token redirects — LiveView use is severed too", %{conn: conn} do
    user = SessionHelpers.user!()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    # The framework revoke path upserts the revocation row (same helper
    # the controller's sign-out rides) — see Token's moduledoc for why
    # not a code_interface on it
    :ok = Actions.revoke(FluxVale.Identity.Token, token)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_token", token)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/apps")
    assert to == "/sign-in?return_to=%2Fapps"
  end

  test "an AccessRule-denied actor redirects (same gate as the API plug)", %{conn: conn} do
    user = SessionHelpers.user!()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    # user's domain is fluxvale.com; a rule for another domain is an
    # allowlist the address is not on
    AccessRule.create!(%{domain: "example.com"}, authorize?: false)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_token", token)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/apps")
    assert to == "/sign-in?return_to=%2Fapps"
  end

  # The connected-remount arm: a live socket's connect_info is the
  # transport's socket map (no request conn, no path to return to) —
  # the redirect falls back to plain /sign-in.
  test "a connect_info that is not a request conn redirects without a return path", %{
    conn: _conn
  } do
    socket = %Phoenix.LiveView.Socket{private: %{connect_info: %{session: %{}}}}

    assert {:halt, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/sign-in"}}}} =
             UserAuth.on_mount(:ensure_authenticated, %{}, %{}, socket)
  end
end
