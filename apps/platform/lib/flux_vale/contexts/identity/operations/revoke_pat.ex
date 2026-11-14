defmodule FluxVale.Identity.Operations.RevokePat do
  @moduledoc """
  Revokes a personal access token (#360) — a policy-checked row write
  (owner or platform admin); the auth lookup refuses a revoked row on
  the next presentation, so the sever is instant.

  Revocation cascades to every token minted from the target (#772):
  the lineage check already severs the children on presentation, and
  marking the rows revoked makes the cap count agree — a revoked
  sign-in frees its minted tokens' slots immediately.

  Idempotent: revoking an already-revoked token is `{:ok, pat}` with
  the original `revoked_at` stamp untouched. The target and its
  subtree revoke in one transaction, so a failed cascade never leaves
  a parent revoked while its children still count as live.
  """

  alias FluxVale.Api
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Repo

  @doc """
  Revokes the PAT given as a record or an id. `opts` ride the read
  and the update (e.g. `authorize?: false` for operator tooling).
  """
  @spec call(term(), PersonalAccessToken.t() | String.t(), keyword()) ::
          {:ok, PersonalAccessToken.t()} | {:error, term()}
  def call(actor, pat_or_id, opts \\ []) do
    case pat_or_id do
      %PersonalAccessToken{} = pat ->
        revoke_tree(pat, actor, opts)

      pat_id when is_binary(pat_id) ->
        case PersonalAccessToken.get(pat_id, Keyword.put(opts, :actor, actor)) do
          {:ok, pat} -> revoke_tree(pat, actor, opts)
          {:error, error} -> {:error, error}
        end
    end
  end

  defp revoke_tree(pat, actor, opts) do
    outcome =
      Repo.transaction(fn ->
        case revoke_one(pat, actor, opts) do
          {:ok, revoked} ->
            revoke_descendants(revoked, actor)
            revoked

          {:error, error} ->
            Repo.rollback(error)
        end
      end)

    case outcome do
      {:ok, revoked} -> {:ok, revoked}
      {:error, error} -> {:error, error}
    end
  end

  defp revoke_one(pat, actor, opts) do
    case PersonalAccessToken.revoke(pat, Keyword.put(opts, :actor, actor)) do
      {:ok, revoked} ->
        # Audit every successful call, idempotent no-ops included:
        # "revoke was asked for" is itself the event. The operator
        # rides actor_id (nil on the no-actor operator path);
        # guarded — a failed row never fails a severed token.
        Api.record_audit_event(%{
          kind: :revoke,
          personal_access_token_id: revoked.id,
          actor_id: actor && actor.id
        })

        {:ok, revoked}

      {:error, error} ->
        {:error, error}
    end
  end

  # The target already passed policy; severing the subtree it minted
  # is the consequence, not a second authorization question. Live
  # children only: a revoked row is already dead, and cascade revokes
  # leave no live grandchild under a dead parent.
  defp revoke_descendants(pat, actor) do
    children =
      PersonalAccessToken.live_derived_children!(pat.user_id, pat.id, DateTime.utc_now())

    Enum.each(children, fn child ->
      case revoke_one(child, actor, authorize?: false) do
        {:ok, revoked} ->
          revoke_descendants(revoked, actor)

        # coveralls-ignore-start - system write on a row just read
        # live; a DB failure rolls the whole tree back
        {:error, _error} ->
          Repo.rollback(:descendant_revoke_failed)
          # coveralls-ignore-stop
      end
    end)
  end
end
