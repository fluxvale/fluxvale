defmodule FluxVale.OAuth.Operations.RefreshTokenTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth

  setup do
    %{client: client!(), user: user!()}
  end

  test "rotates the refresh token and keeps the family", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user, %{"scope" => "instances:read wallet:read"})
    old_refresh = refresh_row(user, tokens.refresh_token)

    assert {:ok, refreshed} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "resource" => resource()
             })

    assert refreshed.access_token =~ ~r/^fvoat_/
    assert refreshed.refresh_token =~ ~r/^fvort_/
    assert refreshed.access_token != tokens.access_token
    assert refreshed.refresh_token != tokens.refresh_token
    assert refreshed.scope == "instances:read wallet:read"

    revoked_refresh = PersonalAccessToken.get!(old_refresh.id, authorize?: false)
    assert revoked_refresh.revoked_at

    new_refresh = refresh_row(user, refreshed.refresh_token)
    assert new_refresh.token_family_id == revoked_refresh.token_family_id
    assert is_nil(new_refresh.revoked_at)
  end

  test "reusing a rotated refresh token severs the whole family", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)

    assert {:ok, _refreshed} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "resource" => resource()
             })

    assert {:error, {:invalid_grant, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "resource" => resource()
             })

    token_rows = rows(user)
    assert Enum.all?(token_rows, &(not is_nil(&1.revoked_at)))
  end

  test "scope narrowing is allowed; broadening is invalid_scope", %{client: client, user: user} do
    %{tokens: broad_tokens} =
      tokens!(client, user, %{"scope" => "instances:read wallet:read"})

    assert {:ok, narrowed} =
             OAuth.refresh_token(%{
               "refresh_token" => broad_tokens.refresh_token,
               "client_id" => client.client_id,
               "resource" => resource(),
               "scope" => "instances:read"
             })

    assert narrowed.scope == "instances:read"

    %{tokens: tokens} = tokens!(client, user, %{"scope" => "instances:read"})

    assert {:error, {:invalid_scope, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "resource" => resource(),
               "scope" => "instances:read wallet:read"
             })
  end

  test "an echoed offline_access is a no-op, not a refusal", %{
    client: client,
    user: user
  } do
    %{tokens: tokens} = tokens!(client, user, %{"scope" => "instances:read"})

    assert {:ok, refreshed} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "scope" => "instances:read offline_access"
             })

    assert refreshed.scope == "instances:read"
  end

  test "an expired refresh token is invalid_grant and leaves the family alone", %{
    client: client,
    user: user
  } do
    random = :crypto.strong_rand_bytes(32)
    raw = "fvort_" <> Base.url_encode64(random, padding: false)
    token_hash = PersonalAccessToken.token_hash(raw)

    token =
      Ash.Seed.seed!(PersonalAccessToken, %{
        name: "OAuth: expired refresh",
        token_hash: token_hash,
        scopes: ["instances:read"],
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        user_id: user.id,
        kind: :oauth_refresh,
        oauth_client_id: client.id,
        resource: resource(),
        token_family_id: Ash.UUIDv7.generate()
      })

    assert {:error, {:invalid_grant, "refresh token is expired"}} =
             OAuth.refresh_token(%{
               "refresh_token" => raw,
               "client_id" => client.client_id
             })

    refreshed = PersonalAccessToken.get!(token.id, authorize?: false)
    assert is_nil(refreshed.revoked_at)
  end

  test "a family tombstone refuses a still-live refresh token", %{
    client: client,
    user: user
  } do
    %{tokens: tokens} = tokens!(client, user)
    family_id = refresh_row(user, tokens.refresh_token).token_family_id

    OAuth.record_audit_event(%{
      kind: :connection_revoked,
      actor_id: user.id,
      token_family_id: family_id,
      metadata: %{"tokens_revoked" => 2}
    })

    assert {:error, {:invalid_grant, "the connection has been revoked"}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id
             })
  end

  test "a mismatched resource is invalid_target", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)

    assert {:error, {:invalid_target, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "resource" => "https://mcp.evil.example/mcp"
             })
  end

  test "an omitted resource inherits the original grant", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)

    assert {:ok, refreshed} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id
             })

    assert refreshed.scope == "instances:read"
  end

  test "a non-URI resource and a non-string scope are refused", %{
    client: client,
    user: user
  } do
    %{tokens: tokens} = tokens!(client, user)

    assert {:error, {:invalid_target, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "resource" => 123
             })

    assert {:error, {:invalid_scope, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "scope" => 123
             })

    assert {:error, {:invalid_scope, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => client.client_id,
               "scope" => "admin"
             })

    assert {:error, {:invalid_request, _message}} =
             OAuth.refresh_token(%{"client_id" => client.client_id})
  end

  test "a refresh token from another client is invalid_grant", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)
    other = client!(%{"client_name" => "Other"})

    assert {:error, {:invalid_grant, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => tokens.refresh_token,
               "client_id" => other.client_id,
               "resource" => resource()
             })
  end

  test "a PAT is not a refresh token and unknown values are invalid_grant", %{
    user: user,
    client: client
  } do
    {:ok, %{token: pat}} =
      Identity.mint_pat(nil, %{user_id: user.id, name: "pat", scopes: []}, authorize?: false)

    assert {:error, {:invalid_grant, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => pat,
               "client_id" => client.client_id,
               "resource" => resource()
             })

    assert {:error, {:invalid_grant, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => "fvort_unknown",
               "client_id" => client.client_id,
               "resource" => resource()
             })

    assert {:error, {:invalid_client, _message}} =
             OAuth.refresh_token(%{
               "refresh_token" => "fvort_unknown",
               "client_id" => "fvoc_unknown",
               "resource" => resource()
             })

    assert {:error, {:invalid_request, _message}} = OAuth.refresh_token(%{})
  end

  defp rows(user), do: PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)

  defp refresh_row(user, raw) do
    hash = PersonalAccessToken.token_hash(raw)

    user
    |> rows()
    |> Enum.find(&(&1.token_hash == hash))
  end
end
