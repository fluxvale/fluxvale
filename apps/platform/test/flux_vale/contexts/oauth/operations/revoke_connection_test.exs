defmodule FluxVale.OAuth.Operations.RevokeConnectionTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth

  setup do
    %{client: client!(), user: user!()}
  end

  test "the owner disconnects the family", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)
    family_id = family_id(user, tokens.access_token)

    assert {:ok, 2} = OAuth.revoke_connection(user, family_id)

    token_rows = rows(user)
    assert Enum.all?(token_rows, &(not is_nil(&1.revoked_at)))
  end

  test "a stranger cannot disconnect another user's family", %{client: client, user: user} do
    %{tokens: tokens} = tokens!(client, user)
    family_id = family_id(user, tokens.access_token)
    stranger = user!()

    assert {:ok, 0} = OAuth.revoke_connection(stranger, family_id)
    token_rows = rows(user)
    assert Enum.all?(token_rows, &is_nil(&1.revoked_at))
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
