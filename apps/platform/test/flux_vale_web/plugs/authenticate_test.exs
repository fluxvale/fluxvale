defmodule FluxValeWeb.Plugs.AuthenticateTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxValeWeb.Plugs.Authenticate

  setup do
    user = User.create!("plug-auth@fluxvale.com", %{}, authorize?: false)
    {:ok, session_token, _claims} = Jwt.token_for_user(user)
    %{user: user, session_token: session_token}
  end

  # The plug's contract is "after fetch_session" (the api_auth pipeline
  # guarantees it); Plug.Test.init_test_session stands in for the plug
  defp plug_conn(conn), do: Plug.Test.init_test_session(conn, %{})

  describe "call/2 bearer" do
    test "resolves the user and sets the Ash actor for a valid bearer token", %{
      conn: conn,
      user: user,
      session_token: token
    } do
      conn =
        conn
        |> plug_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      assert conn.assigns.current_user.id == user.id
      assert Ash.PlugHelpers.get_actor(conn).id == user.id
    end

    test "severs a revoked bearer token instantly", %{conn: conn, session_token: token} do
      :ok = Actions.revoke(FluxVale.Identity.Token, token)

      conn =
        conn
        |> plug_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      refute conn.assigns[:current_user]
    end

    test "garbage bearer falls back to the session (v1 semantics)", %{
      conn: conn,
      user: user
    } do
      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => mint_session(user)})
        |> Plug.Conn.put_req_header("authorization", "Bearer not-a-jwt")
        |> Authenticate.call([])

      assert conn.assigns.current_user.id == user.id
    end

    test "lower-case bearer scheme resolves too (RFC 7235: schemes are case-insensitive)", %{
      conn: conn,
      user: user,
      session_token: token
    } do
      conn =
        conn
        |> plug_conn()
        |> Plug.Conn.put_req_header("authorization", "bearer " <> token)
        |> Authenticate.call([])

      assert conn.assigns.current_user.id == user.id
    end
  end

  describe "call/2 session" do
    test "falls back to the token-backed session", %{conn: conn, user: user} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => mint_session(user)})
        |> Authenticate.call([])

      assert conn.assigns.current_user.id == user.id
      assert Ash.PlugHelpers.get_actor(conn).id == user.id
    end

    test "revocation severs the session fallback too (the v1 upgrade)", %{
      conn: conn,
      user: user
    } do
      token = mint_session(user)
      :ok = Actions.revoke(FluxVale.Identity.Token, token)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => token})
        |> Authenticate.call([])

      refute conn.assigns[:current_user]
    end
  end

  describe "call/2 anonymous" do
    test "no credentials resolve no actor", %{conn: conn} do
      conn =
        conn
        |> plug_conn()
        |> Authenticate.call([])

      refute conn.assigns[:current_user]
      assert is_nil(Ash.PlugHelpers.get_actor(conn))
    end
  end

  # #26 (ADR-0023 Am. 1): a removed rule severs PAT and session access at
  # presentation — within TTL on other nodes, instantly here (cache-off
  # in test). Both paths converge on enforce_access_rules.
  describe "call/2 access gate" do
    setup do
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
      :ok
    end

    test "a valid bearer for a denied address resolves no actor", %{
      conn: conn
    } do
      # The setup user is @fluxvale.com — allowed by the rule; a denied
      # bearer needs its own outsider token
      outsider =
        User.create!("gate-outsider-#{System.unique_integer()}@example.com", %{},
          authorize?: false
        )

      {:ok, token, _claims} = Jwt.token_for_user(outsider)

      conn =
        conn
        |> plug_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      refute conn.assigns[:current_user]
      assert is_nil(Ash.PlugHelpers.get_actor(conn))
    end

    test "a token-backed session for a denied address resolves no actor", %{
      conn: conn
    } do
      user = User.create!("gate-outsider@example.com", %{}, authorize?: false)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => mint_session(user)})
        |> Authenticate.call([])

      refute conn.assigns[:current_user]
    end

    # #285 T3: the gate is user-level — any verified address under the
    # allowlist keeps the account connected.
    test "a second, allowlisted verified address keeps the bearer alive", %{
      conn: conn
    } do
      outsider =
        User.create!("gate-two-#{System.unique_integer()}@example.com", %{}, authorize?: false)

      {:ok, row} =
        UserEmail.add("gate-two-b-#{System.unique_integer()}@fluxvale.com", %{user: outsider},
          authorize?: false
        )

      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)

      {:ok, token, _claims} = Jwt.token_for_user(outsider)

      conn =
        conn
        |> plug_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      assert conn.assigns.current_user.id == outsider.id
    end

    # #285 review P3-1: pins the user-level gate at the token-presentation
    # edge (ensure_allowed_user, NOT ensure_allowed(user.email) — the
    # frozen users.email would admit users the table-backed identity severs).
    test "a user whose only allowed address was removed is severed", %{
      conn: conn
    } do
      outsider =
        User.create!("gate-rm-#{System.unique_integer()}@example.com", %{}, authorize?: false)

      {:ok, row} =
        UserEmail.add("gate-rm-b-#{System.unique_integer()}@fluxvale.com", %{user: outsider},
          authorize?: false
        )

      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)

      # the allowed address goes through the owner path
      assert :ok = UserEmail.remove(row, actor: outsider)

      {:ok, token, _claims} = Jwt.token_for_user(outsider)

      conn =
        conn
        |> plug_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      refute conn.assigns[:current_user]
    end

    test "a pre-T3 user with an allowlisted frozen address and no rows is severed", %{
      conn: conn
    } do
      # A state actions cannot produce (the create mirror stamps a row) —
      # seed! is the sanctioned bypass. Nothing proven, nothing granted:
      # the allowlisted users.email alone must not admit them.
      old_pod =
        Ash.Seed.seed!(User, %{email: "gate-oldpod-#{System.unique_integer()}@fluxvale.com"})

      {:ok, token, _claims} = Jwt.token_for_user(old_pod)

      conn =
        conn
        |> plug_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      refute conn.assigns[:current_user]
      assert is_nil(Ash.PlugHelpers.get_actor(conn))
    end
  end

  # store_in_session writes the live token under "user_token" (subject name
  # + "_token" under require_token_presence_for_authentication?) — the same
  # key SessionController's write produces, so this is the real session shape
  defp mint_session(user) do
    {:ok, token, _claims} = Jwt.token_for_user(user)
    session_conn = Plug.Test.init_test_session(build_conn(), %{})

    user
    |> Ash.Resource.put_metadata(:token, token)
    |> then(&Helpers.store_in_session(session_conn, &1))
    |> Plug.Conn.get_session("user_token")
  end
end
