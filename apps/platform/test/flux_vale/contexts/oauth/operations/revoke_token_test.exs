defmodule FluxVale.OAuth.Operations.RevokeTokenTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth

  setup do
    %{client: client!(), user: user!()}
  end

  test "revoking the access token severs the family immediately", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)

    assert :ok =
             OAuth.revoke_token(%{
               "token" => tokens.access_token,
               "client_id" => client.client_id
             })

    token_rows = rows(user)
    assert Enum.all?(token_rows, &(not is_nil(&1.revoked_at)))
  end

  test "revoking the refresh token severs the family too", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)

    assert :ok =
             OAuth.revoke_token(%{
               "token" => tokens.refresh_token,
               "client_id" => client.client_id
             })

    token_rows = rows(user)
    assert Enum.all?(token_rows, &(not is_nil(&1.revoked_at)))
  end

  test "unknown tokens and foreign clients are silent no-ops", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)
    other = client!(%{"client_name" => "Other"})

    assert :ok =
             OAuth.revoke_token(%{"token" => "fvoat_unknown", "client_id" => client.client_id})

    assert :ok =
             OAuth.revoke_token(%{"token" => tokens.access_token, "client_id" => other.client_id})

    token_rows = rows(user)
    assert Enum.all?(token_rows, &is_nil(&1.revoked_at))
  end

  test "an OAuth row without a family is revoked on its own", %{client: client, user: user} do
    random = :crypto.strong_rand_bytes(32)
    raw = "fvoat_" <> Base.url_encode64(random, padding: false)

    token =
      Ash.Seed.seed!(PersonalAccessToken, %{
        name: "OAuth: orphaned",
        token_hash: PersonalAccessToken.token_hash(raw),
        scopes: [],
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        user_id: user.id,
        kind: :oauth_access,
        oauth_client_id: client.id,
        resource: resource(),
        token_family_id: nil
      })

    assert :ok = OAuth.revoke_token(%{"token" => raw, "client_id" => client.client_id})

    assert %{revoked_at: revoked_at} =
             PersonalAccessToken.get!(token.id, authorize?: false)

    assert revoked_at
  end

  test "missing parameters are invalid_request", %{client: client} do
    assert {:error, :invalid_request} = OAuth.revoke_token(%{})
    assert {:error, :invalid_request} = OAuth.revoke_token(%{"token" => "x"})
    assert {:error, :invalid_request} = OAuth.revoke_token(%{"client_id" => client.client_id})
  end

  defp rows(user), do: PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)
end
