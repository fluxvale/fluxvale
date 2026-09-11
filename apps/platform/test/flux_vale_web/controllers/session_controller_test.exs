defmodule FluxValeWeb.SessionControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias AshAuthentication.Jwt
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
end
