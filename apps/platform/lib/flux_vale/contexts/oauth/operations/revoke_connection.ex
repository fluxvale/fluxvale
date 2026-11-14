defmodule FluxVale.OAuth.Operations.RevokeConnection do
  @moduledoc """
  The settings page's Disconnect (#766): revoke every token row in one
  OAuth family, owner-scoped by the token read policy. The next MCP
  call presents a revoked access token and gets 401.

  Idempotent: an already-severed family still answers `{:ok, count}`.
  """

  @doc """
  Revokes `family_id` for `actor`. Returns `{:ok, count}` or an Ash
  policy/read error.
  """
  @spec call(term(), String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(actor, family_id, opts \\ []) do
    opts = Keyword.put(opts, :actor, actor)

    FluxVale.OAuth.revoke_family(actor.id, family_id, opts)
  end
end
