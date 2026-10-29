defmodule FluxVale.Identity.Operations.AddEmail do
  @moduledoc """
  The actor adds an address to their own account (#285 T3): a PENDING
  `user_emails` row (the `:add` action's owner policy), then the
  sign-in code goes out through the same machinery as first sign-in —
  `request_auth_code`, with its throttle and its AccessRule gate at
  code-send, and the same email copy: a sign-in code was sent.

  The pending row is the claim; the code that lands in the new inbox is
  the proof — `VerifyEmail` consumes it. The claim is kept only while a
  code is outstanding: a refused send removes it (review round 2, P3 —
  a claim against a code that never went out is a cap slot held by
  nothing, and repeated refusals would pin arbitrary addresses).
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.UserEmail

  @doc """
  Creates the pending row for the actor and sends its code. Returns
  `{:ok, row}` — the pending row — or `{:error, reason}`: the resource's
  add failures (cap, uniqueness, shape), or the code-send failures
  (`:throttled`, `:delivery_failed`, `:not_allowed`, `:invalid_address`).

  A code-send failure leaves NO pending row — the send is retried as a
  plain re-add (after the throttle window for `:throttled`; a lifted
  rule for `:not_allowed`). The cleanup is best-effort and pending-only
  at delete time (`:supersede_pending`), so a claim the concurrent
  `VerifyEmail` flips verified mid-window survives.
  """
  @spec call(term(), String.t() | Ash.CiString.t()) :: {:ok, UserEmail.t()} | {:error, term()}
  def call(actor, address) do
    with {:ok, row} <- UserEmail.add(address, %{user: actor}, actor: actor) do
      case Identity.request_auth_code(address) do
        :ok ->
          {:ok, row}

        # No code went out, so no proof is coming: drop the claim (the
        # owner policy grants the destroy; the action's pending-only
        # filter is what keeps a mid-window verified flip intact).
        # The send error is the caller's answer either way.
        {:error, _send_refused} = send_error ->
          _cleanup = Ash.destroy(row, action: :supersede_pending, actor: actor)
          send_error
      end
    end
  end
end
