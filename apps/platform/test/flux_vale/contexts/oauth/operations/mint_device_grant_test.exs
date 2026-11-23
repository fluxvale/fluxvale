defmodule FluxVale.OAuth.Operations.MintDeviceGrantTest do
  @moduledoc false

  # #886: the device-authorization mint — client gate, S256 gate, the
  # scope catalog, resource defaulting, the wire's mint response, and
  # the stored row's shape (hash-only device_code).

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.OAuth.DeviceGrant
  alias FluxVale.OAuth.Operations.MintDeviceGrant
  alias FluxVale.OAuth.Resources

  require Ash.Query

  setup do
    %{client: client!()}
  end

  test "mints a grant with the RFC 8628 mint response shape", %{client: client} do
    minted = device_grant!(client)

    assert minted.device_code =~ ~r/^[A-Za-z0-9_-]{43}$/
    assert minted.grant.user_code =~ ~r/^[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}$/
    assert minted.grant.scopes == ["instances:read"]
    assert minted.grant.resource == resource()
    assert minted.grant.status == :pending
    assert minted.grant.user_id == nil
    assert minted.grant.poll_count == 0
    assert minted.expires_in == DeviceGrant.ttl_seconds()
    assert minted.interval == DeviceGrant.poll_interval_seconds()

    # The stored device_code is the HASH, not the raw capability.
    assert minted.grant.device_code_hash != minted.device_code
    assert byte_size(minted.grant.device_code_hash) == 64
  end

  test "the minted grant resolves by its raw device_code only", %{client: client} do
    minted = device_grant!(client)

    raw_hash =
      :sha256
      |> :crypto.hash(minted.device_code)
      |> Base.encode16(case: :lower)

    assert {:ok, %DeviceGrant{id: id}} =
             DeviceGrant.get_by_device_code_hash(raw_hash, authorize?: false)

    assert id == minted.grant.id

    assert {:error, _not_found} =
             DeviceGrant.get_by_device_code_hash("nonsense", authorize?: false)
  end

  test "an unknown client is invalid_client" do
    assert {:error, {:invalid_client, "unknown client"}} =
             OAuth.mint_device_grant(%{
               "client_id" => "fvoc_nope",
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256"
             })

    assert {:error, {:invalid_client, "client_id is required"}} =
             OAuth.mint_device_grant(%{"code_challenge" => challenge(verifier())})
  end

  test "PKCE with S256 is required — plain and missing are refused", %{client: client} do
    assert {:error, {:invalid_request, "PKCE with S256 is required"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "plain"
             })

    assert {:error, {:invalid_request, "a valid S256 code_challenge is required"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "code_challenge" => "tooshort",
               "code_challenge_method" => "S256"
             })
  end

  test "scopes ride the catalog and offline_access is stripped", %{client: client} do
    minted = device_grant!(client, %{"scope" => "instances:read offline_access wallet:read"})

    assert minted.grant.scopes == ["instances:read", "wallet:read"]

    assert {:error, {:invalid_scope, "scope admin is not supported"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "scope" => "admin",
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256"
             })

    assert {:error, {:invalid_scope, "scope instances:read is repeated"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "scope" => "instances:read instances:read",
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256"
             })
  end

  test "an absent resource binds the configured default; a wrong one is invalid_target", %{
    client: client
  } do
    defaulted = device_grant!(client, %{"resource" => nil})
    assert defaulted.resource_defaulted == true
    assert defaulted.grant.resource == Resources.default()

    assert {:error, {:invalid_target, "resource is not served by this authorization server"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "resource" => "https://mcp.evil.example/mcp",
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256"
             })

    assert {:error, {:invalid_target, "resource must be a URI"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "resource" => 42,
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256"
             })
  end

  test "scope shape tolerates the JSON array and refuses non-strings", %{client: client} do
    minted = device_grant!(client, %{"scope" => ["instances:read", "wallet:read"]})
    assert minted.grant.scopes == ["instances:read", "wallet:read"]

    assert {:error, {:invalid_scope, "scope must be a space-delimited string"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "scope" => ["instances:read", %{"nested" => "map"}],
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256"
             })

    assert {:error, {:invalid_scope, "scope must be a space-delimited string"}} =
             OAuth.mint_device_grant(%{
               "client_id" => client.client_id,
               "scope" => 7,
               "code_challenge" => challenge(verifier()),
               "code_challenge_method" => "S256"
             })
  end

  test "the mint audit names the client and scopes, never the device_code", %{client: client} do
    minted = device_grant!(client, %{"scope" => "instances:read wallet:read"})

    event =
      AuditEvent
      |> Ash.Query.for_read(:stale, %{cutoff: DateTime.add(DateTime.utc_now(), 60, :second)})
      |> Ash.Query.filter(kind == :device_grant_minted and oauth_client_id == ^client.id)
      |> Ash.read!(authorize?: false)
      |> List.last()

    assert event.metadata["scopes"] == ["instances:read", "wallet:read"]
    refute inspect(event) =~ minted.device_code
  end

  test "the user_code collision matcher answers the DB's shape" do
    taken =
      %Ash.Error.Invalid{
        errors: [
          %Ash.Error.Changes.InvalidAttribute{
            field: :user_code,
            message: "has already been taken"
          }
        ]
      }

    assert MintDeviceGrant.user_code_taken?(taken)
    refute MintDeviceGrant.user_code_taken?(%Ash.Error.Invalid{errors: [:other]})
    refute MintDeviceGrant.user_code_taken?(:not_an_error)
  end
end
