defmodule FluxVale.OAuth.Operations.ValidateAuthorizeRequestTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.OAuth

  setup do
    %{client: client!(), user: user!()}
  end

  test "a valid request carries the client, redirect, scopes, resource, and PKCE", %{
    client: client
  } do
    verifier = verifier()

    assert {:ok, request} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "response_type" => "code",
               "scope" => "instances:read offline_access",
               "code_challenge" => challenge(verifier),
               "code_challenge_method" => "S256",
               "resource" => resource(),
               "state" => "abc"
             })

    assert request.client.id == client.id
    assert request.redirect_uri == redirect_uri()
    assert request.scopes == ["instances:read"]
    assert request.resource == resource()
    refute request.resource_defaulted
    assert request.code_challenge == challenge(verifier)
    assert request.state == "abc"
  end

  test "a missing resource binds to the configured default", %{client: client} do
    verifier = verifier()

    assert {:ok, request} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "response_type" => "code",
               "code_challenge" => challenge(verifier),
               "code_challenge_method" => "S256"
             })

    assert request.resource == resource()
    assert request.resource_defaulted
  end

  test "an unknown client is a local error, never a redirect", %{client: client} do
    assert {:error, %{error: :invalid_request, redirect?: false}} =
             OAuth.validate_authorize_request(%{
               "client_id" => "fvoc_unknown",
               "redirect_uri" => redirect_uri(),
               "response_type" => "code"
             })

    assert {:error, %{error: :invalid_request, redirect?: false}} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "redirect_uri" => "https://evil.example/cb",
               "response_type" => "code"
             })
  end

  test "post-validation errors carry the redirect and state back", %{client: client} do
    assert {:error, %{error: :unsupported_response_type, redirect?: true, state: "s"}} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "response_type" => "token",
               "state" => "s"
             })

    assert {:error, %{error: :invalid_request, redirect?: true}} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "response_type" => "code",
               "code_challenge" => "short",
               "code_challenge_method" => "S256"
             })

    assert {:error, %{error: :invalid_request, redirect?: true}} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "response_type" => "code",
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "plain"
             })
  end

  test "scopes stay inside the OAuth catalog", %{client: client} do
    params = %{
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "response_type" => "code",
      "code_challenge" => challenge(verifier()),
      "code_challenge_method" => "S256"
    }

    invalid = Map.put(params, "scope", "instances:read admin")

    assert {:error, %{error: :invalid_scope, redirect?: true}} =
             OAuth.validate_authorize_request(invalid)

    duplicate = Map.put(params, "scope", "instances:read instances:read")

    assert {:error, %{error: :invalid_scope, redirect?: true}} =
             OAuth.validate_authorize_request(duplicate)

    pseudo = Map.put(params, "scope", "offline_access")
    assert {:ok, request} = OAuth.validate_authorize_request(pseudo)

    assert request.scopes == []
  end

  test "a present resource must match exactly", %{client: client} do
    params = %{
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "response_type" => "code",
      "code_challenge" => challenge(verifier()),
      "code_challenge_method" => "S256"
    }

    mismatched = Map.put(params, "resource", "https://mcp.evil.example/mcp")

    assert {:error, %{error: :invalid_target, redirect?: true}} =
             OAuth.validate_authorize_request(mismatched)
  end

  test "state is capped" do
    client = client!()

    assert {:error, %{error: :invalid_request, redirect?: true}} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "redirect_uri" => redirect_uri(),
               "response_type" => "code",
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256",
               "state" => String.duplicate("x", 513)
             })
  end

  test "client_id and redirect_uri are required before any redirect", %{client: client} do
    assert {:error, %{error: :invalid_request, redirect?: false}} =
             OAuth.validate_authorize_request(%{
               "redirect_uri" => redirect_uri(),
               "response_type" => "code"
             })

    assert {:error, %{error: :invalid_request, redirect?: false}} =
             OAuth.validate_authorize_request(%{
               "client_id" => client.client_id,
               "response_type" => "code"
             })

    assert {:error, %{error: :invalid_request, redirect?: false}} =
             OAuth.validate_authorize_request(%{
               "client_id" => "",
               "redirect_uri" => redirect_uri()
             })
  end

  test "scopes may arrive as a list; malformed values are refused", %{client: client} do
    base = %{
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "response_type" => "code",
      "code_challenge" => challenge(verifier()),
      "code_challenge_method" => "S256"
    }

    list_scope = Map.put(base, "scope", ["instances:read"])
    assert {:ok, request} = OAuth.validate_authorize_request(list_scope)
    assert request.scopes == ["instances:read"]

    unknown = Map.put(base, "scope", ["admin"])

    assert {:error, %{error: :invalid_scope, redirect?: true}} =
             OAuth.validate_authorize_request(unknown)

    malformed = Map.put(base, "scope", 123)

    assert {:error, %{error: :invalid_scope, redirect?: true}} =
             OAuth.validate_authorize_request(malformed)

    # Nested brackets decode to a list of maps; interpolating one would
    # raise Protocol.UndefinedError instead of answering invalid_scope.
    nested = Map.put(base, "scope", [%{"nested" => "value"}])

    assert {:error, %{error: :invalid_scope, redirect?: true}} =
             OAuth.validate_authorize_request(nested)
  end

  test "a non-URI resource and a non-string state are refused", %{client: client} do
    base = %{
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "response_type" => "code",
      "code_challenge" => challenge(verifier()),
      "code_challenge_method" => "S256"
    }

    malformed_resource = Map.put(base, "resource", 123)

    assert {:error, %{error: :invalid_target, redirect?: true}} =
             OAuth.validate_authorize_request(malformed_resource)

    for malformed <- [123, %{"nested" => "map"}, ["list"]] do
      malformed_state = Map.put(base, "state", malformed)

      assert {:error, %{error: :invalid_request, redirect?: true, state: nil}} =
               OAuth.validate_authorize_request(malformed_state)
    end
  end

  test "a non-map request is a local invalid_request" do
    assert {:error, %{error: :invalid_request, redirect?: false}} =
             OAuth.validate_authorize_request("nope")
  end
end
