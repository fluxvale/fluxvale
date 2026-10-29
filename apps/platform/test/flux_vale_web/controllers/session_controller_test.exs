defmodule FluxValeWeb.SessionControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
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

  # #285 review P3-1: pins the user-level gate at SessionController
  # (ensure_allowed_user, NOT ensure_allowed(user.email) — the frozen
  # users.email would sever users the table-backed identity admits).
  describe "user-level gate pins (#285 T3 — create/2)" do
    setup do
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
      :ok
    end

    test "a multi-address user gets through on the allowed verified address", %{conn: conn} do
      user =
        User.create!("multi-in-#{System.unique_integer()}@example.com", %{}, authorize?: false)

      {:ok, row} =
        UserEmail.add("multi-in-b-#{System.unique_integer()}@fluxvale.com", %{user: user},
          authorize?: false
        )

      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)
      {:ok, token, _claims} = Jwt.token_for_user(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> fetch_flash()
        |> FluxValeWeb.SessionController.create(%{"token" => token})

      assert redirected_to(conn) == ~p"/"
      assert Plug.Conn.get_session(conn, "user_token")
    end

    test "a user whose only allowed address was removed is severed", %{conn: conn} do
      user =
        User.create!("multi-out-#{System.unique_integer()}@example.com", %{}, authorize?: false)

      {:ok, row} =
        UserEmail.add("multi-out-b-#{System.unique_integer()}@fluxvale.com", %{user: user},
          authorize?: false
        )

      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)

      # the allowed address goes through the owner path
      assert :ok = UserEmail.remove(row, actor: user)

      {:ok, token, _claims} = Jwt.token_for_user(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> fetch_flash()
        |> FluxValeWeb.SessionController.create(%{"token" => token})

      assert redirected_to(conn) == ~p"/sign-in"
      refute Plug.Conn.get_session(conn, "user_token")
    end

    test "a pre-T3 user with an allowlisted frozen address and no rows is severed", %{conn: conn} do
      # A state actions cannot produce (the create mirror stamps a row) —
      # seed! is the sanctioned bypass. Nothing proven, nothing granted:
      # the allowlisted users.email alone must not admit them.
      old_pod =
        Ash.Seed.seed!(User, %{email: "old-pod-#{System.unique_integer()}@fluxvale.com"})

      {:ok, token, _claims} = Jwt.token_for_user(old_pod)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> fetch_flash()
        |> FluxValeWeb.SessionController.create(%{"token" => token})

      assert redirected_to(conn) == ~p"/sign-in"
      refute Plug.Conn.get_session(conn, "user_token")
    end
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
