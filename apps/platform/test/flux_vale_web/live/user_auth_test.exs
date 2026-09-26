defmodule FluxValeWeb.UserAuthTest do
  @moduledoc false

  # The :authenticated live_session's on_mount gate (#74): session
  # resolution with revocation + AccessRule parity, then the redirect.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.SessionHelpers

  test "a valid session mounts and assigns the actor", %{conn: conn} do
    {_user, conn} = SessionHelpers.user_with_session(conn)

    {:ok, view, html} = live(conn, ~p"/apps")

    assert has_element?(view, "h1", "Catalog")
    assert html =~ "Sign out"
  end

  test "no session redirects to /sign-in", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{})

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/apps")
    assert to == ~p"/sign-in"
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
    assert to == ~p"/sign-in"
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
    assert to == ~p"/sign-in"
  end
end
