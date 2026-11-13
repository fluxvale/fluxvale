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

  The mint takes a per-family advisory lock and checks the revoke
  tombstone inside it: a connection severed while a refresh is in
  flight cannot mint a pair that outlives the disconnect.
  """

  alias FluxVale.Api
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.Repo

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

    mint = %{
      access_raw: access_raw,
      refresh_raw: refresh_raw,
      now: now,
      params: params,
      metadata: metadata,
      scopes: scopes,
      user_id: user_id,
      family_id: family_id
    }

    case Repo.transaction(fn -> mint_transaction(mint, opts) end) do
      {:ok, minted} ->
        {:ok, minted}

      {:error, :connection_revoked} ->
        {:error, :connection_revoked}

      # coveralls-ignore-start - a rollback is a DB outage mid-mint.
      {:error, error} ->
        {:error, error}
        # coveralls-ignore-stop
    end
  end

  defp mint_transaction(mint, opts) do
    lock_family(mint.family_id)

    if revoked?(mint.family_id) do
      Repo.rollback(:connection_revoked)
    else
      mint_pair(mint, opts)
    end
  end

  defp mint_pair(mint, opts) do
    # The refresh half goes first: if a concurrent revoke catches one of
    # the two rows, the long-lived credential is the one it catches.
    case create(
           mint.refresh_raw,
           :oauth_refresh,
           DateTime.add(mint.now, @refresh_ttl_seconds, :second),
           mint.params,
           mint.metadata,
           opts
         ) do
      {:ok, refresh} ->
        mint_access(mint, refresh, opts)

      # coveralls-ignore-start - DB outage before either half exists.
      {:error, error} ->
        Repo.rollback(error)
        # coveralls-ignore-stop
    end
  end

  defp mint_access(mint, refresh, opts) do
    case create(
           mint.access_raw,
           :oauth_access,
           DateTime.add(mint.now, @access_ttl_seconds, :second),
           mint.params,
           mint.metadata,
           opts
         ) do
      {:ok, access} ->
        record_mint(access, mint.user_id)
        record_mint(refresh, mint.user_id)

        %{
          access_token: mint.access_raw,
          refresh_token: mint.refresh_raw,
          expires_in: @access_ttl_seconds,
          access: access,
          refresh: refresh,
          family_id: mint.family_id,
          scopes: mint.scopes
        }

      # coveralls-ignore-start - the access half failing is a DB outage
      # mid-mint; the refresh half is revoked and the client restarts.
      {:error, error} ->
        PersonalAccessToken.revoke(refresh, authorize?: false)
        Repo.rollback(error)
        # coveralls-ignore-stop
    end
  end

  defp lock_family(family_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [family_id])
  end

  defp revoked?(family_id) do
    AuditEvent
    |> Ash.Query.for_read(:for_family, %{token_family_id: family_id})
    |> Ash.exists?(authorize?: false)
  end

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
