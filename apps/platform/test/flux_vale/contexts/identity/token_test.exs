defmodule FluxVale.Identity.TokenTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias AshAuthentication.Plug.Helpers
  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Identity.User

  setup do
    user = User.create!("token-test@fluxvale.com", %{}, authorize?: false)
    %{user: user}
  end

  describe "session tokens" do
    test "mint with the 60-day absolute TTL and authenticate the bearer", %{user: user} do
      assert {:ok, token, %{"exp" => exp, "iat" => iat}} =
               AshAuthentication.Jwt.token_for_user(user)

      # Absolute TTL, baked at mint (60d mid-band of ADR-0003's 30–90d, #20)
      assert exp - iat == 60 * 24 * 60 * 60

      assert bearer_user(token).id == user.id
    end

    test "sever bearer auth instantly on revocation", %{user: user} do
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
      assert bearer_user(token).id == user.id

      # store_all_tokens? + require_token_presence_for_authentication?:
      # revocation is a live-store check, not a JWT-expiry wait. The framework
      # path (upsert over the stored row) — see Token's moduledoc
      assert :ok = Actions.revoke(FluxVale.Identity.Token, token)

      refute bearer_user(token)
    end
  end

  # The real bearer path (JWT verify → revocation + presence checks → actor),
  # same helper the API pipeline will use (#24)
  defp bearer_user(token) do
    :get
    |> Plug.Test.conn("/")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Helpers.retrieve_from_bearer(:flux_vale)
    |> Map.get(:assigns)
    |> Map.get(:current_user)
  end
end
