defmodule FluxVale.OAuth.Operations.ExchangeCode do
  @moduledoc """
  The `authorization_code` grant (#766): validate the code's client,
  redirect URI, PKCE verifier, and resource; consume it exactly once;
  mint the access/refresh pair for the code's user and scopes.

  A consumed code is a reuse signal: the family that code produced is
  revoked and the answer is `invalid_grant`. The same is true when two
  exchanges race the consume — one wins, the loser revokes the family.
  """

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.AuthorizationCode
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.Operations.MintTokens
  alias FluxVale.OAuth.Operations.RecordAuditEvent
  alias FluxVale.OAuth.Operations.RevokeFamily
  alias FluxVale.OAuth.PKCE
  alias FluxVale.OAuth.Resources

  @doc """
  Returns `{:ok, token_response}` or `{:error, {error, description}}`.
  """
  @spec call(map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def call(params) do
    with {:ok, client} <- fetch_client(param(params, :client_id)),
         {:ok, code} <- fetch_code(param(params, :code)) do
      cond do
        not is_nil(code.consumed_at) ->
          reuse(code, "authorization code has already been used")

        not DateTime.after?(code.expires_at, DateTime.utc_now()) ->
          {:error, {:invalid_grant, "authorization code is expired"}}

        code.client_id != client.id ->
          {:error, {:invalid_grant, "authorization code was issued to another client"}}

        code.redirect_uri != param(params, :redirect_uri) ->
          {:error, {:invalid_grant, "redirect_uri does not match the authorization request"}}

        true ->
          exchange(code, client, params)
      end
    end
  end

  defp exchange(code, client, params) do
    with {:ok, resource} <- resource(code, param(params, :resource)),
         :ok <- verify_pkce(code, param(params, :code_verifier)) do
      family_id = Ash.UUIDv7.generate()

      changeset =
        code
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:token_family_id, family_id)
        |> Ash.Changeset.for_update(:consume, %{}, authorize?: false)

      case Ash.update(changeset) do
        {:ok, consumed} ->
          mint(consumed, client, family_id, resource)

        # coveralls-ignore-start - two exchanges racing one code: the
        # loser's UPDATE sees consumed_at set; not sequentially stageable.
        {:error, _stale} ->
          reuse(stale_code(code), "authorization code has already been used")
          # coveralls-ignore-stop
      end
    end
  end

  defp mint(code, client, family_id, resource) do
    case MintTokens.call(%{
           client: client,
           user_id: code.user_id,
           scopes: code.scopes,
           resource: resource,
           family_id: family_id,
           grant_type: "authorization_code"
         }) do
      {:ok, minted} ->
        RecordAuditEvent.call(%{
          kind: :token_issued,
          oauth_client_id: client.id,
          actor_id: code.user_id,
          token_family_id: family_id,
          resource: resource,
          metadata: %{"scopes" => code.scopes}
        })

        Client.touch_last_used(client, authorize?: false)

        {:ok,
         %{
           access_token: minted.access_token,
           token_type: "Bearer",
           expires_in: minted.expires_in,
           refresh_token: minted.refresh_token,
           scope: Enum.join(code.scopes, " ")
         }}

      # coveralls-ignore-start - a fresh code's family cannot be
      # tombstoned before the exchange; the guard is the shared mint's.
      {:error, :connection_revoked} ->
        {:error, {:invalid_grant, "the connection has been revoked"}}

      # coveralls-ignore-stop

      # coveralls-ignore-start - DB outage mid-mint; the token endpoint
      # answers server_error and the client retries the flow.
      {:error, _error} ->
        {:error, {:server_error, "could not issue the token pair"}}
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start - the race arm's helper: a code fetched
  # before the winner committed has no family yet; the re-read is what
  # the loser revokes. Not sequentially stageable.
  defp stale_code(code) do
    case AuthorizationCode.get_by_code_hash(code.code_hash, authorize?: false) do
      {:ok, fresh} -> fresh
      {:error, _not_found} -> code
    end
  end

  # coveralls-ignore-stop

  defp reuse(code, description) do
    if code.token_family_id do
      RevokeFamily.call(code.user_id, code.token_family_id, authorize?: false)
    end

    RecordAuditEvent.call(%{
      kind: :code_reuse,
      oauth_client_id: code.client_id,
      actor_id: code.user_id,
      token_family_id: code.token_family_id,
      resource: code.resource,
      metadata: %{}
    })

    {:error, {:invalid_grant, description}}
  end

  defp resource(code, nil), do: {:ok, code.resource}

  defp resource(code, resource) when is_binary(resource) do
    if resource == code.resource and Resources.valid?(resource) do
      {:ok, resource}
    else
      {:error, {:invalid_target, "resource does not match the authorization request"}}
    end
  end

  defp resource(_code, _resource),
    do: {:error, {:invalid_target, "resource must be a URI"}}

  defp verify_pkce(code, verifier) do
    if PKCE.verify(verifier, code.code_challenge) do
      :ok
    else
      {:error, {:invalid_grant, "code_verifier does not match the PKCE challenge"}}
    end
  end

  defp fetch_client(client_id) when is_binary(client_id) and client_id != "" do
    case Client.get_by_client_id(client_id, authorize?: false) do
      {:ok, client} -> {:ok, client}
      {:error, _not_found} -> {:error, {:invalid_client, "unknown client"}}
    end
  end

  defp fetch_client(_client_id),
    do: {:error, {:invalid_request, "client_id is required"}}

  defp fetch_code(code) when is_binary(code) and code != "" do
    hash = PersonalAccessToken.token_hash(code)

    case AuthorizationCode.get_by_code_hash(hash, authorize?: false) do
      {:ok, row} -> {:ok, row}
      {:error, _not_found} -> {:error, {:invalid_grant, "authorization code is invalid"}}
    end
  end

  defp fetch_code(_code), do: {:error, {:invalid_request, "code is required"}}

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
