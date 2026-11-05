defmodule FluxVale.Accounts.Operations.ResolveInvite do
  @moduledoc """
  The token path's read seam (slice 4 of #408): a raw token resolves to
  the invite row and its state — `{:open, invite}`, or one of the
  terminal words the accept page renders a sentence for. The accept and
  decline seams build on this resolution; the page renders from it.

  authorize?: false — the token IS the bearer credential: the lookup is
  by SHA-256 of a value only the emailed link holds, and a resolved row
  confers nothing by itself (the write-side identity fence lives in
  AcceptInvite).
  """

  alias FluxVale.Accounts.MembershipInvite

  @type resolution ::
          {:open, MembershipInvite.t()} | :accepted | :revoked | :expired

  @spec call(term()) :: {:ok, resolution()} | {:error, :unknown_token}
  def call(raw_token)

  def call(raw_token) when is_binary(raw_token) do
    hash = MembershipInvite.token_hash(raw_token)

    case MembershipInvite.get_by_token_hash(hash, authorize?: false) do
      {:ok, invite} -> {:ok, state(invite)}
      {:error, _not_found} -> {:error, :unknown_token}
    end
  end

  # A missing/empty query param is an unknown token, not a crash.
  def call(_no_token), do: {:error, :unknown_token}

  # The read action loads the `:state` calculation — the row's own
  # state axis, evaluated at read time (expiry included).
  defp state(%MembershipInvite{state: :open} = invite), do: {:open, invite}
  defp state(%MembershipInvite{state: terminal}), do: terminal
end
