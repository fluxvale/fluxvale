defmodule FluxVale.Identity.Operations.AddEmail do
  @moduledoc """
  The actor adds an address to their own account (#285 T3): a PENDING
  `user_emails` row (the `:add` action's owner policy), then the
  sign-in code goes out through the same machinery as first sign-in —
  `request_auth_code`, with its throttle and its AccessRule gate at
  code-send, and the same email copy: a sign-in code was sent.

  The pending row is the claim; the code that lands in the new inbox is
  the proof — `VerifyEmail` consumes it.
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.UserEmail

  @doc """
  Creates the pending row for the actor and sends its code. Returns
  `{:ok, row}` — the pending row — or `{:error, reason}`: the resource's
  add failures (cap, uniqueness, shape), or the code-send failures.
  A code-send failure leaves the pending row in place: `:throttled` and
  `:delivery_failed` retry as a remove + re-add after the throttle
  window; `:not_allowed` needs the rule lifted first — no wait window
  helps, so a retry loop would only litter pending claims against the
  cap.
  """
  @spec call(term(), String.t() | Ash.CiString.t()) :: {:ok, UserEmail.t()} | {:error, term()}
  def call(actor, address) do
    with {:ok, row} <- UserEmail.add(address, %{user: actor}, actor: actor),
         :ok <- Identity.request_auth_code(address) do
      {:ok, row}
    end
  end
end
