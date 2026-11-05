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

  # #462: the return path lands the visitor back where they came from —
  # and never outside the site. These are controller-level pins (the
  # LiveView carry is SignInTest's, the guard table ReturnPathTest's).
  describe "return path (#462)" do
    setup do
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
      :ok
    end

    defp signed_in_redirect(conn, params) do
      user =
        User.create!("return-to-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      {:ok, token, _claims} = Jwt.token_for_user(user)

      conn
      |> Plug.Test.init_test_session(%{})
      |> fetch_flash()
      |> FluxValeWeb.SessionController.create(Map.put(params, "token", token))
      |> redirected_to()
    end

    test "a local return_to redirects there", %{conn: conn} do
      assert signed_in_redirect(conn, %{"return_to" => "/feedback/some-post"}) ==
               "/feedback/some-post"
    end

    test "a crafted external return_to is refused and falls back to the default landing" do
      # The shapes the guard exists for: protocol-relative, its
      # backslash twins (leading and mid-string), a newline (Plug's
      # header write would raise), and an absolute scheme.
      assert signed_in_redirect(build_conn(), %{"return_to" => "//evil.com"}) == ~p"/"
      assert signed_in_redirect(build_conn(), %{"return_to" => "/\\evil.com"}) == ~p"/"
      assert signed_in_redirect(build_conn(), %{"return_to" => "/feedback/a\\b"}) == ~p"/"
      assert signed_in_redirect(build_conn(), %{"return_to" => "/feedback\nx"}) == ~p"/"
      assert signed_in_redirect(build_conn(), %{"return_to" => "https://evil.com"}) == ~p"/"
    end

    test "no return_to keeps the default landing" do
      assert signed_in_redirect(build_conn(), %{}) == ~p"/"
    end

    # The retry arm (#462 review): a failed session write must not drop
    # the carried return path, or the flow's own contract forks — the
    # visitor re-requests a code on a sign-in page that forgot where
    # they were going.
    test "a failed session write re-links sign-in with the return path", %{conn: conn} do
      # The describe setup's fluxvale.com allowlist refuses this address:
      # the session write fails.
      user =
        User.create!("return-retry-#{System.unique_integer()}@example.com", %{},
          authorize?: false
        )

      {:ok, token, _claims} = Jwt.token_for_user(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> fetch_flash()
        |> FluxValeWeb.SessionController.create(%{"token" => token, "return_to" => "/feedback/x"})

      assert redirected_to(conn) == "/sign-in?return_to=%2Ffeedback%2Fx"
      refute Plug.Conn.get_session(conn, "user_token")
    end
  end

  # #74: sign-out revokes the session's tokens (the store, not just the
  # cookie) and clears the session — the revoked token can't ride the
  # session back in. #473: the destination is the landing page, not the
  # sign-in form.
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

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed out."
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
  # through the browser pipeline's CSRF gate. #473: sign-out lands on
  # the landing page with the flash visible — the landing template
  # renders the flash group, pinned here by following the redirect.
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

    assert redirected_to(conn) == ~p"/"
    assert Plug.Conn.get_session(conn, "user_token") == nil

    # The landing renders the "Signed out." flash (the flash rides the
    # cookie session through recycle). The landing H1 doubles as the
    # session-termination pin (#205): a surviving session would render
    # the dashboard with a different H1.
    landing_conn =
      conn
      |> recycle()
      |> get("/")

    page = html_response(landing_conn, 200)

    assert page =~ "Signed out."
    assert page =~ "Managed cloud platform for open source applications"
  end
end
