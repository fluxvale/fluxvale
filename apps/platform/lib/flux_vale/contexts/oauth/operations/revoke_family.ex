defmodule FluxVale.OAuth.Operations.RevokeFamily do
  @moduledoc """
  Severs one OAuth connection family (#766): every token row sharing a
  `token_family_id`, revoked through the existing token-revocation path
  so the audit rows and the idempotent stamp stay identical to a PAT
  revoke.

  System callers (refresh-reuse detection, RFC 7009) pass
  `authorize?: false`; the settings page passes the actor and lets the
  owner policy decide.
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken

  @doc """
  Revokes every row in `user_id`'s `family_id`. Returns `{:ok, count}`.
  """
  @spec call(term(), term(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(user_id, family_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    actor_opts = Keyword.put(opts, :actor, actor)
    read_opts = Keyword.put_new(actor_opts, :authorize?, not is_nil(actor))
    revoke_opts = Keyword.delete(opts, :actor)

    with {:ok, rows} <- PersonalAccessToken.list_oauth_family(user_id, family_id, read_opts) do
      Enum.each(rows, fn row -> Identity.revoke_pat(actor, row, revoke_opts) end)
      {:ok, length(rows)}
    end
  end
end
