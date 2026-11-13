defmodule FluxVale.OAuth.Operations.MintTokens do
  @moduledoc """
  Mints one OAuth access/refresh pair (#766) into the existing
  `personal_access_tokens` table: the access token is a short-lived
  scoped row (`fvoat_`, one hour) and the refresh token is the same
  table with the refresh kind (`fvort_`, thirty days), both bound to
  the client, the resource, and a shared rotation family.

  The API audit gets the same `:mint` row a PAT mint writes, so
  "what did this token do" stays one query. The caller records the
  OAuth-specific audit event (`token_issued` / `token_refreshed`).
  """

  alias FluxVale.Api
  alias FluxVale.Identity.PersonalAccessToken

  @access_prefix "fvoat_"
  @refresh_prefix "fvort_"
  @access_ttl_seconds 60 * 60
  @refresh_ttl_seconds 30 * 24 * 60 * 60
  @name_max_length 100

  @doc """
  Returns `{:ok, %{access_token, refresh_token, expires_in, access,
  refresh, family_id}}` or `{:error, term()}`.
  """
  @spec call(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(params, opts \\ []) do
    opts = Keyword.put_new(opts, :authorize?, false)

    client = params.client
    user_id = params.user_id
    scopes = params.scopes || []
    resource = params.resource
    family_id = params.family_id
    grant_type = params.grant_type

    access_raw = @access_prefix <> random()
    refresh_raw = @refresh_prefix <> random()
    now = DateTime.utc_now()

    metadata = %{
      "minted_via" => "oauth",
      "grant_type" => grant_type,
      "client_id" => client.client_id,
      "resource" => resource
    }

    with {:ok, access} <-
           create(
             access_raw,
             :oauth_access,
             DateTime.add(now, @access_ttl_seconds, :second),
             params,
             metadata,
             opts
           ) do
      case create(
             refresh_raw,
             :oauth_refresh,
             DateTime.add(now, @refresh_ttl_seconds, :second),
             params,
             metadata,
             opts
           ) do
        {:ok, refresh} ->
          record_mint(access, user_id)
          record_mint(refresh, user_id)

          {:ok,
           %{
             access_token: access_raw,
             refresh_token: refresh_raw,
             expires_in: @access_ttl_seconds,
             access: access,
             refresh: refresh,
             family_id: family_id,
             scopes: scopes
           }}

        {:error, error} ->
          # The access half exists; a half-pair is not a connection.
          # Revoke it and let the client restart the flow.
          PersonalAccessToken.revoke(access, authorize?: false)
          {:error, error}
      end
    end
  end

  @doc "The access token lifetime the token endpoint reports."
  @spec access_ttl_seconds() :: pos_integer()
  def access_ttl_seconds, do: @access_ttl_seconds

  defp create(raw, kind, expires_at, params, metadata, opts) do
    attrs = %{
      name: token_name(params.client),
      scopes: params.scopes || [],
      expires_at: expires_at,
      user_id: params.user_id
    }

    changeset =
      PersonalAccessToken
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:token_hash, PersonalAccessToken.token_hash(raw))
      |> Ash.Changeset.set_argument(:kind, kind)
      |> Ash.Changeset.set_argument(:oauth_client_id, params.client.id)
      |> Ash.Changeset.set_argument(:resource, params.resource)
      |> Ash.Changeset.set_argument(:token_family_id, params.family_id)
      |> Ash.Changeset.set_argument(:metadata, metadata)
      |> Ash.Changeset.for_create(:create_oauth, attrs, opts)

    Ash.create(changeset)
  end

  defp token_name(client) do
    ("OAuth: " <> client.client_name)
    |> String.codepoints()
    |> Enum.take(@name_max_length)
    |> Enum.join()
  end

  defp record_mint(token, user_id) do
    Api.record_audit_event(%{
      kind: :mint,
      personal_access_token_id: token.id,
      actor_id: user_id
    })
  end

  defp random do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
