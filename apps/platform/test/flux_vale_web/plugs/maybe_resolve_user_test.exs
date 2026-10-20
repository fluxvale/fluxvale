defmodule FluxValeWeb.Plugs.MaybeResolveUserTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.Plugs.MaybeResolveUser

  describe "call/2" do
    test "no session resolves to a nil current_user" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> MaybeResolveUser.call([])

      assert conn.assigns.current_user == nil
    end

    test "a valid session assigns the user — display-only chrome" do
      user = SessionHelpers.user!()
      signed_in = SessionHelpers.sign_in(build_conn(), user)

      conn = MaybeResolveUser.call(signed_in, [])

      assert conn.assigns.current_user.id == user.id
    end

    test "a garbage token resolves to nil, never an error" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"user_token" => "not-a-real-token"})
        |> MaybeResolveUser.call([])

      assert conn.assigns.current_user == nil
    end
  end
end
