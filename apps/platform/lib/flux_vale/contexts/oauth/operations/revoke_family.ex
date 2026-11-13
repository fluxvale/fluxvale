defmodule FluxVale.OAuth.Operations.RevokeFamily do
  @moduledoc """
  Severs one OAuth connection family (#766): every token row sharing a
  `token_family_id`, revoked through the existing token-revocation path
  so the audit rows and the idempotent stamp stay identical to a PAT
  revoke. A `connection_revoked` tombstone is committed in the same
  transaction; `MintTokens` takes the same family advisory lock and
  refuses a tombstoned family, so a refresh already in flight cannot
  mint a pair that survives the disconnect.

  System callers (refresh-reuse detection, RFC 7009) pass
  `authorize?: false`; the settings page passes the actor and lets the
  owner policy decide.
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.Repo

  @doc """
  Revokes every row in `user_id`'s `family_id`. Returns `{:ok, count}`.
  """
  @spec call(term(), term(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(user_id, family_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    actor_opts = Keyword.put(opts, :actor, actor)
    read_opts = Keyword.put_new(actor_opts, :authorize?, not is_nil(actor))
    revoke_opts = Keyword.delete(opts, :actor)

    case Repo.transaction(fn -> sever(user_id, family_id, actor, read_opts, revoke_opts) end) do
      {:ok, count} ->
        {:ok, count}

      # coveralls-ignore-start - a rollback is a DB outage mid-sever.
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # The advisory lock serializes this sever against a concurrent
  # MintTokens for the same family: whichever starts second waits, then
  # sees the tombstone (mint) or the freshly minted rows (revoke). The
  # tombstone is the durable "this family is dead" fact — mint checks it
  # inside the same lock.
  defp sever(user_id, family_id, actor, read_opts, revoke_opts) do
    lock_family(family_id)

    case PersonalAccessToken.list_oauth_family(user_id, family_id, read_opts) do
      {:ok, rows} ->
        Enum.each(rows, fn row -> Identity.revoke_pat(actor, row, revoke_opts) end)
        record_tombstone(user_id, family_id, length(rows))
        length(rows)

      # coveralls-ignore-start - a read failure is a DB outage mid-sever.
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  defp lock_family(family_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [family_id])
  end

  defp record_tombstone(user_id, family_id, count) do
    AuditEvent
    |> Ash.Changeset.for_create(:record, %{
      kind: :connection_revoked,
      actor_id: user_id,
      token_family_id: family_id,
      metadata: %{"tokens_revoked" => count}
    })
    |> Ash.create!(authorize?: false)
  end
end
