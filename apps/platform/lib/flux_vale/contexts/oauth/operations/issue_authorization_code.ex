defmodule FluxVale.OAuth.Operations.IssueAuthorizationCode do
  @moduledoc """
  The consent screen's Approve (#766): mint one 60-second, single-use
  authorization code bound to the client, the exact redirect URI, the
  PKCE challenge, the granted scopes, and the resource.

  The raw code exists only in the return — the row keeps its SHA-256
  hash. The approval and code-issuance audit rows are written here;
  the redirect itself belongs to the controller.
  """

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.AuthorizationCode
  alias FluxVale.OAuth.Operations.RecordAuditEvent

  @ttl_seconds 60

  @doc """
  `request` is the validated map from
  `FluxVale.OAuth.validate_authorize_request/1` plus `:user`.

  Returns `{:ok, %{code: raw, record: %AuthorizationCode{}}}`.
  """
  @spec call(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(request, opts \\ []) do
    opts = Keyword.put_new(opts, :authorize?, false)
    raw = "fvac_" <> random()
    client = request.client
    user = request.user

    attrs = %{
      code_hash: PersonalAccessToken.token_hash(raw),
      redirect_uri: request.redirect_uri,
      scopes: request.scopes,
      resource: request.resource,
      code_challenge: request.code_challenge,
      code_challenge_method: "S256",
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second),
      client_id: client.id,
      user_id: user.id
    }

    changeset = Ash.Changeset.for_create(AuthorizationCode, :issue, attrs, opts)

    case Ash.create(changeset) do
      {:ok, record} ->
        metadata = %{
          "resource_defaulted" => request.resource_defaulted,
          "scopes" => request.scopes,
          "code_id" => record.id
        }

        RecordAuditEvent.call(%{
          kind: :authorize_approved,
          oauth_client_id: client.id,
          actor_id: user.id,
          resource: request.resource,
          metadata: metadata
        })

        RecordAuditEvent.call(%{
          kind: :code_issued,
          oauth_client_id: client.id,
          actor_id: user.id,
          resource: request.resource,
          metadata: metadata
        })

        {:ok, %{code: raw, record: record}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "The code lifetime the redirect relies on."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  defp random do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
