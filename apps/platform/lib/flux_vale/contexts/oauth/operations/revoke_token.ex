defmodule FluxVale.OAuth.Operations.RevokeToken do
  @moduledoc """
  RFC 7009 revocation (#766): revoking either half of a pair severs the
  whole connection family, so the next API/MCP call is 401 immediately.

  Unknown tokens and tokens belonging to another client answer `:ok`
  with no action — the endpoint never becomes a token-enumeration
  oracle. The controller always answers 200.
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.Operations.RecordAuditEvent
  alias FluxVale.OAuth.Operations.RevokeFamily

  @doc """
  Returns `:ok` or `{:error, :invalid_request}` when `client_id`/`token`
  are missing (the controller answers the RFC's 400).
  """
  @spec call(map()) :: :ok | {:error, :invalid_request}
  def call(params) do
    with client_id when is_binary(client_id) and client_id != "" <-
           param(params, :client_id),
         token_value when is_binary(token_value) and token_value != "" <-
           param(params, :token) do
      do_revoke(client_id, token_value)
    else
      _missing -> {:error, :invalid_request}
    end
  end

  defp do_revoke(client_id, token_value) do
    hash = PersonalAccessToken.token_hash(token_value)

    with {:ok, token} <- PersonalAccessToken.get_by_token_hash(hash, authorize?: false),
         {:ok, client} <- Client.get_by_client_id(client_id, authorize?: false),
         true <- token.oauth_client_id == client.id do
      revoke(token)
    else
      _unknown_or_foreign -> :ok
    end
  end

  defp revoke(%PersonalAccessToken{token_family_id: nil} = token) do
    Identity.revoke_pat(nil, token, authorize?: false)
    audit(token)
    :ok
  end

  defp revoke(%PersonalAccessToken{token_family_id: family_id} = token) do
    RevokeFamily.call(token.user_id, family_id, authorize?: false)
    audit(token)
    :ok
  end

  defp audit(token) do
    RecordAuditEvent.call(%{
      kind: :token_revoked,
      oauth_client_id: token.oauth_client_id,
      actor_id: token.user_id,
      token_family_id: token.token_family_id,
      resource: token.resource,
      metadata: %{}
    })
  end

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
