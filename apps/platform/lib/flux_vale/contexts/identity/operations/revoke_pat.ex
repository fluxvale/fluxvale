defmodule FluxVale.Identity.Operations.RevokePat do
  @moduledoc """
  Revokes a personal access token (#360) — a policy-checked row write
  (owner or platform admin); the auth lookup refuses a revoked row on
  the next presentation, so the sever is instant.

  Idempotent: revoking an already-revoked token is `{:ok, pat}` with
  the original `revoked_at` stamp untouched.
  """

  alias FluxVale.Api
  alias FluxVale.Identity.PersonalAccessToken

  @doc """
  Revokes the PAT given as a record or an id. `opts` ride the read
  and the update (e.g. `authorize?: false` for operator tooling).
  """
  @spec call(term(), PersonalAccessToken.t() | String.t(), keyword()) ::
          {:ok, PersonalAccessToken.t()} | {:error, term()}
  def call(actor, pat_or_id, opts \\ []) do
    case pat_or_id do
      %PersonalAccessToken{} = pat ->
        revoke(pat, actor, opts)

      pat_id when is_binary(pat_id) ->
        case PersonalAccessToken.get(pat_id, Keyword.put(opts, :actor, actor)) do
          {:ok, pat} -> revoke(pat, actor, opts)
          {:error, error} -> {:error, error}
        end
    end
  end

  defp revoke(pat, actor, opts) do
    case PersonalAccessToken.revoke(pat, Keyword.put(opts, :actor, actor)) do
      {:ok, revoked} ->
        # Audit every successful call, idempotent no-ops included:
        # "revoke was asked for" is itself the event. The operator
        # rides actor_id (nil on the no-actor operator path);
        # guarded — a failed row never fails a severed token.
        Api.record_audit_event(%{
          kind: :revoke,
          personal_access_token_id: pat.id,
          actor_id: actor && actor.id
        })

        {:ok, revoked}

      {:error, error} ->
        {:error, error}
    end
  end
end
