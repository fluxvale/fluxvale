defmodule FluxVale.OAuth.Operations.PollDeviceGrantTest do
  @moduledoc false

  # #886: the token endpoint's device grant — the §3.5 state machine
  # (pending → interval → approved → PKCE → consume-once → the pair),
  # the refusal matrix, and the one-time delivery.

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth
  alias FluxVale.OAuth.DeviceGrant

  setup do
    %{client: client!(), user: user!()}
  end

  defp poll_params(client, minted, overrides) do
    Map.merge(
      %{
        "client_id" => client.client_id,
        "device_code" => minted.device_code,
        "code_verifier" => minted.verifier
      },
      overrides
    )
  end

  defp poll(client, minted, overrides \\ %{}, opts \\ []) do
    params = poll_params(client, minted, overrides)
    OAuth.poll_device_grant(params, opts)
  end

  defp grant_by_user_code(minted) do
    DeviceGrant.get_by_user_code!(minted.grant.user_code, authorize?: false)
  end

  test "a pending grant answers authorization_pending and counts the poll", %{client: client} do
    minted = device_grant!(client)

    assert {:error, {:authorization_pending, _reason}} = poll(client, minted)

    grant = grant_by_user_code(minted)
    assert grant.poll_count == 1
    assert grant.last_polled_at != nil
  end

  test "a poll sooner than the interval answers slow_down; the exact interval counts", %{
    client: client
  } do
    minted = device_grant!(client)

    assert {:error, {:authorization_pending, _reason}} = poll(client, minted)

    grant = grant_by_user_code(minted)
    now = DateTime.add(grant.last_polled_at, 2, :second)

    assert {:error, {:slow_down, _backoff}} = poll(client, minted, %{}, now: now)

    after_refused = grant_by_user_code(minted)
    assert after_refused.poll_count == 1, "the refused poll must not count"
    assert after_refused.last_polled_at == grant.last_polled_at

    # The boundary: exactly `interval` seconds after the last counted
    # poll is NOT too soon — the diff-is-strictly-less comparison.
    boundary = DateTime.add(grant.last_polled_at, DeviceGrant.poll_interval_seconds(), :second)

    assert {:error, {:authorization_pending, _counted}} = poll(client, minted, %{}, now: boundary)

    assert grant_by_user_code(minted).poll_count == 2
  end

  test "an empty scope mints the identify-only grant", %{client: client} do
    minted = device_grant!(client, %{"scope" => nil})
    assert minted.grant.scopes == []
  end

  test "an approved grant delivers the pair exactly once, through the shared mint", %{
    client: client,
    user: user
  } do
    minted = approved_device_grant!(client, user)

    assert {:ok, tokens} = poll(client, minted)

    assert tokens.access_token =~ ~r/^fvoat_/
    assert tokens.refresh_token =~ ~r/^fvort_/
    assert tokens.token_type == "Bearer"
    assert tokens.expires_in == 3600
    assert tokens.scope == "instances:read"

    # The family binds the pair to the approving user + client + resource.
    raw_access_hash = PersonalAccessToken.token_hash(tokens.access_token)

    access = PersonalAccessToken.get_by_token_hash!(raw_access_hash, authorize?: false)
    assert access.user_id == user.id
    assert access.oauth_client_id == client.id
    assert access.resource == resource()

    # The one-time delivery: the row is consumed, the second poll reads
    # expired_token.
    grant = grant_by_user_code(minted)
    assert grant.status == :consumed

    assert {:error, {:expired_token, _reason}} = poll(client, minted)
  end

  test "a wrong verifier is invalid_grant and does not burn the grant", %{
    client: client,
    user: user
  } do
    minted = approved_device_grant!(client, user)
    stranger = verifier()

    assert {:error, {:invalid_grant, "code_verifier does not match the PKCE challenge"}} =
             poll(client, minted, %{"code_verifier" => stranger})

    grant = grant_by_user_code(minted)
    assert grant.status == :approved, "the honest CLI can still redeem"

    assert {:ok, _tokens_map} = poll(client, minted)
  end

  test "a device_code issued to another client is invalid_grant before any state moves", %{
    client: client,
    user: user
  } do
    other = client!(%{"client_name" => "Other Client"})

    pending_minted = device_grant!(client)

    assert {:error, {:invalid_grant, "device_code was issued to another client"}} =
             poll(other, pending_minted)

    pending_grant = grant_by_user_code(pending_minted)
    assert pending_grant.status == :pending
    assert pending_grant.poll_count == 0
    assert pending_grant.last_polled_at == nil

    minted = approved_device_grant!(client, user)

    assert {:error, {:invalid_grant, "device_code was issued to another client"}} =
             poll(other, minted)

    grant = grant_by_user_code(minted)
    assert grant.status == :approved
  end

  test "a denied grant answers access_denied forever after", %{client: client, user: user} do
    minted = device_grant!(client)
    {:ok, _denied} = OAuth.deny_device_grant(minted.grant, actor: user)

    assert {:error, {:access_denied, _reason}} = poll(client, minted)
  end

  test "an expired grant answers expired_token regardless of status", %{
    client: client,
    user: user
  } do
    minted = approved_device_grant!(client, user)
    past = DateTime.add(DateTime.utc_now(), DeviceGrant.ttl_seconds() + 1, :second)

    assert {:error, {:expired_token, _reason}} = poll(client, minted, %{}, now: past)
  end

  test "an unknown device_code answers expired_token, never not-found", %{client: client} do
    minted = device_grant!(client)

    assert {:error, {:expired_token, _reason}} = poll(client, minted, %{"device_code" => "nope"})
    # A missing device_code is the same answer — the hash of "" finds
    # nothing, and the wire never distinguishes.
    assert {:error, {:expired_token, _missing}} = poll(client, minted, %{"device_code" => nil})
  end

  test "malformed device_code shapes answer expired_token, never a 500", %{client: client} do
    minted = device_grant!(client)

    # A JSON object, a number, and a list — the wire's parsers can
    # hand each to the endpoint; none may reach :crypto (the hostile
    # finding: the hash guard, not a crash report).
    assert {:error, {:expired_token, _map}} = poll(client, minted, %{"device_code" => %{}})
    assert {:error, {:expired_token, _number}} = poll(client, minted, %{"device_code" => 42})
  end

  test "an unknown or missing client is invalid_client", %{client: client, user: user} do
    minted = approved_device_grant!(client, user)

    assert {:error, {:invalid_client, "unknown client"}} =
             poll(client, minted, %{"client_id" => "fvoc_nope"})

    assert {:error, {:invalid_client, "client_id is required"}} =
             poll(client, minted, %{"client_id" => nil})
  end

  test "the wire's grant_type and the shared interval" do
    assert OAuth.device_grant_type() == "urn:ietf:params:oauth:grant-type:device_code"
    assert DeviceGrant.poll_interval_seconds() == 5
  end
end
