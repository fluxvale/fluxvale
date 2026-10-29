defmodule FluxValeWeb.SessionControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRule

  # Controller-invocation level (the LiveView flow is covered in
  # SignInTest): create/2 must refuse a token whose owner a rule now
  # denies — the controller accepts any valid token, including one minted
  # before the rule existed (#26's stale-token seam).
  test "a denied owner's valid token writes no session", %{conn: conn} do
    user =
      User.create!("session-gate-#{System.unique_integer()}@example.com", %{}, authorize?: false)

    {:ok, token, _claims} = Jwt.token_for_user(user)

    AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> fetch_flash()
      |> FluxValeWeb.SessionController.create(%{"token" => token})

    assert redirected_to(conn) == ~p"/sign-in"
    refute Plug.Conn.get_session(conn, "user_token")
  end

  # #74: sign-out revokes the session's tokens (the store, not just the
  # cookie) and clears the session — the revoked token can't ride the
  # session back in.
  test "delete/2 revokes the tokens and clears the session", %{conn: conn} do
    user =
      User.create!("sign-out-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

    {:ok, token, _claims} = Jwt.token_for_user(user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_token", token)
      |> fetch_flash()
      |> FluxValeWeb.SessionController.delete(%{})

    assert redirected_to(conn) == ~p"/sign-in"
    assert Plug.Conn.get_session(conn, "user_token") == nil

    # Ground truth: the revoked session token no longer authenticates
    # (the same resolution chain the on_mount gate rides)
    assert :error =
             Helpers.authenticate_resource_from_session(
               User,
               %{"user_token" => token},
               :flux_vale,
               []
             )
  end

  # The route end-to-end (the layout's form shape): method-override POST
  # through the browser pipeline's CSRF gate.
  test "DELETE /auth/session signs out through the route", %{conn: conn} do
    user =
      User.create!("route-sign-out-#{System.unique_integer()}@fluxvale.com", %{},
        authorize?: false
      )

    {:ok, token, _claims} = Jwt.token_for_user(user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_token", token)
      |> put_req_header("x-csrf-token", Phoenix.Controller.get_csrf_token())
      |> delete(~p"/auth/session")

    assert redirected_to(conn) == ~p"/sign-in"
    assert Plug.Conn.get_session(conn, "user_token") == nil
  end
end
