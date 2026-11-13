defmodule FluxVale.OAuth.Operations.ExchangeCodeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuthorizationCode

  setup do
    %{client: client!(), user: user!()}
  end

  test "exchanges a code for a one-hour access token and a rotating refresh token", %{
    client: client,
    user: user
  } do
    issued = issue_code!(client, user, %{"scope" => "instances:read wallet:read"})

    assert {:ok, tokens} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => issued.request.verifier,
               "resource" => resource()
             })

    assert tokens.access_token =~ ~r/^fvoat_[A-Za-z0-9_-]{43}$/
    assert tokens.refresh_token =~ ~r/^fvort_[A-Za-z0-9_-]{43}$/
    assert tokens.token_type == "Bearer"
    assert tokens.expires_in == 3600
    assert tokens.scope == "instances:read wallet:read"

    token_rows = rows(user)
    [access, refresh] = Enum.sort_by(token_rows, & &1.kind)
    assert access.kind == :oauth_access
    assert refresh.kind == :oauth_refresh
    assert access.token_family_id == refresh.token_family_id
    assert access.resource == resource()
    assert refresh.resource == resource()
    assert access.scopes == ["instances:read", "wallet:read"]
  end

  test "a wrong verifier is refused without consuming the code", %{client: client, user: user} do
    issued = issue_code!(client, user)

    assert {:error, {:invalid_grant, _message}} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => verifier(),
               "resource" => resource()
             })

    assert {:ok, _tokens} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => issued.request.verifier,
               "resource" => resource()
             })
  end

  test "a mismatched redirect URI is invalid_grant", %{client: client, user: user} do
    issued = issue_code!(client, user)

    assert {:error, {:invalid_grant, _message}} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => "http://127.0.0.1:53682/other",
               "code_verifier" => issued.request.verifier,
               "resource" => resource()
             })
  end

  test "a mismatched resource is invalid_target and does not consume the code", %{
    client: client,
    user: user
  } do
    issued = issue_code!(client, user)

    assert {:error, {:invalid_target, _message}} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => issued.request.verifier,
               "resource" => "https://mcp.evil.example/mcp"
             })

    assert {:ok, _tokens} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => issued.request.verifier,
               "resource" => resource()
             })
  end

  test "a non-URI resource is invalid_target", %{client: client, user: user} do
    issued = issue_code!(client, user)

    assert {:error, {:invalid_target, _message}} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => issued.request.verifier,
               "resource" => 123
             })
  end

  test "a reused code is invalid_grant and revokes the family it produced", %{
    client: client,
    user: user
  } do
    issued = issue_code!(client, user)

    params = %{
      "code" => issued.code,
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "code_verifier" => issued.request.verifier,
      "resource" => resource()
    }

    assert {:ok, _tokens} = OAuth.exchange_code(params)
    assert {:error, {:invalid_grant, _message}} = OAuth.exchange_code(params)

    token_rows = rows(user)
    assert Enum.all?(token_rows, &(not is_nil(&1.revoked_at)))
  end

  test "an omitted resource inherits the code's grant", %{client: client, user: user} do
    issued = issue_code!(client, user)

    assert {:ok, tokens} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => issued.request.verifier
             })

    assert tokens.access_token =~ ~r/^fvoat_/
  end

  test "missing parameters are protocol errors", %{client: client} do
    assert {:error, {:invalid_request, "code is required"}} =
             OAuth.exchange_code(%{"client_id" => client.client_id})

    assert {:error, {:invalid_request, "client_id is required"}} =
             OAuth.exchange_code(%{"code" => "fvac_whatever"})
  end

  test "an expired code is invalid_grant", %{client: client, user: user} do
    verifier = verifier()
    random = :crypto.strong_rand_bytes(32)
    raw = "fvac_" <> Base.url_encode64(random, padding: false)

    # Ash.seed! for a state the issue action cannot produce: an
    # already-expired code (AGENTS: seed only for unreachable states).
    Ash.Seed.seed!(AuthorizationCode, %{
      code_hash: PersonalAccessToken.token_hash(raw),
      redirect_uri: redirect_uri(),
      scopes: ["instances:read"],
      resource: resource(),
      code_challenge: challenge(verifier),
      code_challenge_method: "S256",
      expires_at: DateTime.add(DateTime.utc_now(), -1, :second),
      client_id: client.id,
      user_id: user.id
    })

    assert {:error, {:invalid_grant, "authorization code is expired"}} =
             OAuth.exchange_code(%{
               "code" => raw,
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => verifier,
               "resource" => resource()
             })
  end

  test "another client cannot redeem the code", %{client: client, user: user} do
    issued = issue_code!(client, user)
    other = client!(%{"client_name" => "Other"})

    assert {:error, {:invalid_grant, _message}} =
             OAuth.exchange_code(%{
               "code" => issued.code,
               "client_id" => other.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => issued.request.verifier,
               "resource" => resource()
             })
  end

  test "an unknown code, client, or missing parameters are protocol errors", %{client: client} do
    assert {:error, {:invalid_grant, _message}} =
             OAuth.exchange_code(%{
               "code" => "fvac_unknown",
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "code_verifier" => verifier()
             })

    assert {:error, {:invalid_client, _message}} =
             OAuth.exchange_code(%{
               "code" => "fvac_unknown",
               "client_id" => "fvoc_unknown",
               "redirect_uri" => redirect_uri(),
               "code_verifier" => verifier()
             })

    assert {:error, {:invalid_request, _message}} = OAuth.exchange_code(%{})
  end

  defp rows(user) do
    PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)
  end
end
