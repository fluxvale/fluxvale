defmodule FluxVale.Billing.TopupOutcomeMail do
  @moduledoc """
  The email twin of the in-app top-up result state (#377, landing in
  #391): the buyer gets a durable email on every FRESH outcome
  transition — webhook, return-page reconcile, or the hourly expiry
  sweep.

  The operations are terminal-once, so an `{:ok, %Topup{}}` result is
  exactly one caller's fresh-transition receipt: every other racer
  (a replayed delivery, a second page load, the webhook arriving
  after the reconcile) answers `:already_completed` /
  `:already_terminal` and mails nothing. The once-ness is inherited,
  not re-derived.

  Pending never mails — it is not an outcome, the webhook may be in
  flight. A mail failure logs and never fails the caller: the
  outcome itself already happened, and the surface state plus the
  gateway's retry own the recovery. Operations take zero diffs by
  design — this is the notify layer the callers invoke.
  """

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.Billing.Wallet
  alias FluxVale.Mailer

  require Logger

  @doc """
  Passthrough for a completion result — mails the buyer on the one
  fresh transition, hands the result back for the caller's response
  policy.
  """
  @spec on_completion(term()) :: term()
  def on_completion({:ok, %Topup{} = topup}) do
    deliver_completed(topup)
    {:ok, topup}
  end

  def on_completion(result), do: result

  @doc "Passthrough for a failure result — same once-only discipline."
  @spec on_failure(term()) :: term()
  def on_failure({:ok, %Topup{} = topup}) do
    deliver_not_completed(topup)
    {:ok, topup}
  end

  def on_failure(result), do: result

  @doc "Mails the completed outcome: amount credited plus the resulting balance."
  @spec deliver_completed(Topup.t()) :: :ok
  def deliver_completed(%Topup{buyer_email: buyer_email} = topup)
      when is_binary(buyer_email) do
    # The wallet provably exists — the credit this mail reports just
    # posted to it (CompleteTopup's own resolution).
    {:ok, wallet} = Wallet.get_by_organization(topup.organization_id, authorize?: false)
    {:ok, balance} = Billing.balance(wallet, authorize?: false)

    case Mailer.deliver_topup_completed(buyer_email, topup.amount_cents, balance) do
      {:ok, _delivery} -> :ok
      {:error, reason} -> log_failure(topup, reason)
    end
  end

  # The wizard always captures a buyer email; a hand-built row
  # (tests, seeds) need not — nothing to send, not an error.
  def deliver_completed(%Topup{} = topup) do
    log_skip(topup)
  end

  @doc "Mails the not-completed outcome (failed or expired) with the retry link."
  @spec deliver_not_completed(Topup.t()) :: :ok
  def deliver_not_completed(%Topup{buyer_email: buyer_email, status: status} = topup)
      when is_binary(buyer_email) and status in [:failed, :expired] do
    case Mailer.deliver_topup_not_completed(buyer_email, status) do
      {:ok, _delivery} -> :ok
      {:error, reason} -> log_failure(topup, reason)
    end
  end

  # A non-terminal row has no honest outcome copy — pending is not an
  # outcome, and the mailer speaks only the two terminal words.
  def deliver_not_completed(%Topup{} = topup) do
    log_skip(topup)
  end

  defp log_failure(topup, reason) do
    Logger.error(
      "Top-up outcome mail failed for #{topup.id} (#{topup.status}): #{inspect(reason)}"
    )

    :ok
  end

  defp log_skip(topup) do
    Logger.info("Top-up #{topup.id} (#{topup.status}) has no mailable outcome — mail skipped")
    :ok
  end
end
