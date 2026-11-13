defmodule FluxVale.OAuth.Operations.RevokeConnectionTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuditEvent

  setup do
    %{client: client!(), user: user!()}
  end

  test "the owner disconnects the family", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)
    family_id = family_id(user, tokens.access_token)

    assert {:ok, 2} = OAuth.revoke_connection(user, family_id)

    token_rows = rows(user)
    assert Enum.all?(token_rows, &(not is_nil(&1.revoked_at)))

    assert {:ok, [tombstone]} =
             AuditEvent
             |> Ash.Query.for_read(:for_family, %{token_family_id: family_id})
             |> Ash.read(authorize?: false)

    assert tombstone.kind == :connection_revoked
  end

  test "a stranger cannot disconnect another user's family", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)
    family_id = family_id(user, tokens.access_token)
    stranger = user!()

    assert {:ok, 0} = OAuth.revoke_connection(stranger, family_id)
    token_rows = rows(user)
    assert Enum.all?(token_rows, &is_nil(&1.revoked_at))
  end

  test "the connection read carries the latest last-used stamp", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)
    hash = PersonalAccessToken.token_hash(tokens.access_token)
    token_rows = rows(user)
    access = Enum.find(token_rows, &(&1.token_hash == hash))
    {:ok, _stamped} = PersonalAccessToken.touch_last_used(access, authorize?: false)

    assert {:ok, [connection]} = OAuth.list_connections(user)
    assert connection.client_name == "MCP Test Client"
    assert connection.scopes == ["instances:read"]
    assert connection.created_at
    assert connection.last_used_at
  end

  test "an expired family is not a live connection", %{client: client, user: user} do
    Ash.Seed.seed!(PersonalAccessToken, %{
      name: "OAuth: expired",
      token_hash: PersonalAccessToken.token_hash("fvoat_expired"),
      scopes: [],
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
      user_id: user.id,
      kind: :oauth_access,
      oauth_client_id: client.id,
      resource: resource(),
      token_family_id: Ash.UUIDv7.generate()
    })

    assert {:ok, []} = OAuth.list_connections(user)
  end

  test "an unknown family is an idempotent zero", %{user: user} do
    assert {:ok, 0} = OAuth.revoke_connection(user, Ash.UUIDv7.generate())
  end

  defp rows(user), do: PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)

  defp family_id(user, raw) do
    hash = PersonalAccessToken.token_hash(raw)
    token_rows = rows(user)
    Enum.find(token_rows, &(&1.token_hash == hash)).token_family_id
  end
end
