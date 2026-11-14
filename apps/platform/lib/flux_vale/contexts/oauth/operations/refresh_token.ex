defmodule FluxVale.OAuth.Operations.RefreshToken do
  @moduledoc """
  The `refresh_token` grant (#766) with strict rotation: the presented
  refresh row is revoked conditionally, then a fresh access/refresh
  pair is minted into the same family. A revoked or already-rotated
  refresh token is a reuse signal — the whole family is severed.

  Scope narrowing is allowed (the request's `scope` must be a subset of
  the refresh token's grant); broadening is `invalid_scope`. The
  resource is inherited when omitted and must match exactly when
  present.
  """

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.Resources
  alias FluxVale.Repo

  @doc """
  Returns `{:ok, token_response}` or `{:error, {error, description}}`.
  """
  @spec call(map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def call(params) do
    with {:ok, client} <- fetch_client(param(params, :client_id)),
         {:ok, token} <- fetch_refresh(param(params, :refresh_token)) do
      cond do
        token.kind != :oauth_refresh ->
          {:error, {:invalid_grant, "not a refresh token"}}

        token.oauth_client_id != client.id ->
          {:error, {:invalid_grant, "refresh token was issued to another client"}}

        not is_nil(token.revoked_at) ->
          reuse(token, "refresh token has been revoked")

        not DateTime.after?(token.expires_at, DateTime.utc_now()) ->
          {:error, {:invalid_grant, "refresh token is expired"}}

        true ->
          rotate(token, client, params)
      end
    end
  end

  defp rotate(token, client, params) do
    with {:ok, resource} <- resource(token, param(params, :resource)),
         {:ok, scopes} <- scopes(token, param(params, :scope)) do
      transaction = Repo.transaction(fn -> consume_and_mint(token, client, resource, scopes) end)
      rotate_result(transaction, token, client, resource, scopes)
    end
  end

  defp rotate_result({:ok, minted}, token, client, resource, scopes),
    do: refreshed(token, client, minted, resource, scopes)

  # coveralls-ignore-start - two refreshes racing one token: the
  # loser's rollback is not sequentially stageable.
  defp rotate_result({:error, :stale}, token, _client, _resource, _scopes),
    do: reuse(token, "refresh token has already been rotated")

  # coveralls-ignore-stop

  defp rotate_result({:error, :connection_revoked}, _token, _client, _resource, _scopes),
    do: {:error, {:invalid_grant, "the connection has been revoked"}}

  # coveralls-ignore-start - a mint failure rolls the consumption back,
  # so the client retries the same refresh token safely.
  defp rotate_result({:error, _mint_failed}, _token, _client, _resource, _scopes),
    do: {:error, {:server_error, "could not issue the token pair"}}

  # coveralls-ignore-stop

  # Consumption and the fresh pair commit together: a transient mint
  # failure rolls the refresh row back to live, so a retry does not trip
  # reuse detection and force a new consent.
  defp consume_and_mint(token, client, resource, scopes) do
    case PersonalAccessToken.revoke_if_live(token, authorize?: false) do
      {:ok, _revoked} ->
        mint_into_family(token, client, resource, scopes)

      # coveralls-ignore-start - two refreshes racing one token: the
      # loser's UPDATE sees revoked_at set; not sequentially stageable.
      {:error, _stale} ->
        Repo.rollback(:stale)
        # coveralls-ignore-stop
    end
  end

  defp mint_into_family(token, client, resource, scopes) do
    case FluxVale.OAuth.mint_tokens(%{
           client: client,
           user_id: token.user_id,
           scopes: scopes,
           resource: resource,
           family_id: token.token_family_id,
           grant_type: "refresh_token"
         }) do
      {:ok, minted} ->
        minted

      {:error, :connection_revoked} ->
        Repo.rollback(:connection_revoked)

      # coveralls-ignore-start - DB outage mid-mint; the transaction
      # rolls the consumption back.
      {:error, _error} ->
        Repo.rollback(:mint_failed)
        # coveralls-ignore-stop
    end
  end

  defp refreshed(token, client, minted, resource, scopes) do
    FluxVale.OAuth.record_audit_event(%{
      kind: :token_refreshed,
      oauth_client_id: client.id,
      actor_id: token.user_id,
      token_family_id: token.token_family_id,
      resource: resource,
      metadata: %{"scopes" => scopes}
    })

    Client.touch_last_used(client, authorize?: false)

    {:ok,
     %{
       access_token: minted.access_token,
       token_type: "Bearer",
       expires_in: minted.expires_in,
       refresh_token: minted.refresh_token,
       scope: Enum.join(scopes, " ")
     }}
  end

  defp reuse(token, description) do
    FluxVale.OAuth.revoke_family(token.user_id, token.token_family_id, authorize?: false)

    FluxVale.OAuth.record_audit_event(%{
      kind: :refresh_reuse,
      oauth_client_id: token.oauth_client_id,
      actor_id: token.user_id,
      token_family_id: token.token_family_id,
      resource: token.resource,
      metadata: %{}
    })

    {:error, {:invalid_grant, description}}
  end

  defp resource(token, nil), do: {:ok, token.resource}

  defp resource(token, resource) when is_binary(resource) do
    if resource == token.resource and Resources.valid?(resource) do
      {:ok, resource}
    else
      {:error, {:invalid_target, "resource does not match the original grant"}}
    end
  end

  defp resource(_token, _resource),
    do: {:error, {:invalid_target, "resource must be a URI"}}

  defp scopes(token, nil), do: {:ok, token.scopes}

  defp scopes(token, scope) when is_binary(scope) do
    requested =
      scope
      |> String.split()
      |> Enum.reject(&(&1 == ""))
      # offline_access is a consent-time no-op; a client echoing its
      # grant back must not be told the scope was never granted.
      |> Scopes.strip_oauth()

    with :ok <- validate(requested) do
      subset(requested, token.scopes)
    end
  end

  defp scopes(_token, _scope),
    do: {:error, {:invalid_scope, "scope must be a space-delimited string"}}

  defp validate(scopes) do
    case Scopes.validate_oauth(scopes) do
      :ok ->
        :ok

      {:error, {_kind, invalid}} ->
        {:error, {:invalid_scope, "scope #{invalid} is not supported"}}
    end
  end

  defp subset(requested, granted) do
    case Enum.find(requested, &(&1 not in granted)) do
      nil -> {:ok, Scopes.strip_oauth(requested)}
      invalid -> {:error, {:invalid_scope, "scope #{invalid} was not granted"}}
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

  defp fetch_refresh(refresh_token) when is_binary(refresh_token) and refresh_token != "" do
    hash = PersonalAccessToken.token_hash(refresh_token)

    case PersonalAccessToken.get_by_token_hash(hash, authorize?: false) do
      {:ok, row} -> {:ok, row}
      {:error, _not_found} -> {:error, {:invalid_grant, "refresh token is invalid"}}
    end
  end

  defp fetch_refresh(_refresh_token),
    do: {:error, {:invalid_request, "refresh_token is required"}}

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
