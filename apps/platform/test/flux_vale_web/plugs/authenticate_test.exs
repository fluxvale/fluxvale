defmodule FluxValeWeb.Plugs.AuthenticateTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Identity.User
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
