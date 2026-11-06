defmodule FluxVale.Identity.Operations.ResolveInviteLink do
  @moduledoc """
  The accept link's read-only seam (#502): a raw token resolves to the
  invitation's state WITHOUT consuming it — the landing page renders the
  honest row before any accept click (the Accounts ResolveInvite
  posture). The state word is the whole answer: the link already proves
  everything it names, so no identity rides the read.

  authorize?: false — the token IS the credential: the lookup is by
  SHA-256 of a value only the emailed link holds, and a resolved state
  confers nothing by itself (the AcceptInvitation posture — no actor
  exists on an anonymous landing).
  """

  alias FluxVale.Identity.User

  @spec call(term()) ::
          {:ok, :pending | :accepted | :withdrawn | :expired} | {:error, :unknown_token}
  def call(raw_token)

  def call(raw_token) when is_binary(raw_token) do
    hash = User.token_hash(raw_token)

    case fetch_user_by_hash(hash) do
      {:ok, nil} ->
        {:error, :unknown_token}

      {:ok, user} ->
        state_verdict(user)

      # coveralls-ignore-start - DB read failure: the same class as
      # AcceptInvitation's :lookup_failed arm — not simulatable under
      # the sandbox. The landing's only error render is :unknown_token,
      # so the failure folds there (the page answers "not valid"
      # instead of crashing).
      {:error, _read_failed} ->
        {:error, :unknown_token}
        # coveralls-ignore-stop
    end
  end

  # A missing/empty query param is an unknown token, not a crash.
  def call(_no_token), do: {:error, :unknown_token}

  # The pre-read verdict (the AcceptInvitation posture): the
  # :accept_invite write's WHERE filter is the true arbiter, this only
  # renders the row's truth. :none with a resolvable hash is
  # structurally impossible — the hash is only ever written alongside
  # invited_at (:invite/:reinvite) — so a hand-built row is the only
  # writer that could reach it, and :unknown_token is the honest answer.
  defp state_verdict(user) do
    case user.invite_state do
      :pending -> {:ok, :pending}
      :accepted -> {:ok, :accepted}
      :withdrawn -> {:ok, :withdrawn}
      :expired -> {:ok, :expired}
      :none -> {:error, :unknown_token}
    end
  end

  defp fetch_user_by_hash(hash) do
    User
    |> Ash.Query.for_read(:get_by_invite_token_hash, %{token_hash: hash})
    |> Ash.read_one(authorize?: false)
  end
end
