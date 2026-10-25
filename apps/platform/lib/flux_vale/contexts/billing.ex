defmodule FluxVale.Billing do
  @moduledoc """
  Billing: wallets and the append-only ledger (#120, ADR-0028 §3) — the
  settlement core every other billing lane attaches to.

  Prepaid credits are integer US cents; the ledger only ever carries
  whole cents, and flat-rate accrual fractions pool per-wallet in
  `Wallet.carryover` (micro-cents). Refunds are compensating entries
  (`reverse_entry/2`), never row mutations (ADR-0029). Postings run
  `authorize?: false` — the operations are the system seam; actors read
  their org's wallet and ledger through the policies, and the one
  actor-facing posting is the admin goodwill credit (`LedgerEntry
  :grant_goodwill`, #140).
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  # AshAdmin exposure (#140, ADR-0027 §3 — opt-in, admin policies ride
  # ActorIsPlatformAdmin like every exposed domain): the goodwill
  # surface only. Wallet (read-only, to find the wallet) and LedgerEntry
  # (reads + the grant_goodwill create); Topup stays out — buyer
  # PII, no role in a goodwill grant.
  admin do
    show?(true)
    show_resources([FluxVale.Billing.Wallet, FluxVale.Billing.LedgerEntry])
  end

  alias FluxVale.Billing.Operations

  resources do
    resource(FluxVale.Billing.LedgerEntry)
    resource(FluxVale.Billing.Topup)
    resource(FluxVale.Billing.Wallet)
  end

  # Operations are verb-named modules under operations/ (see
  # apps/platform/AGENTS.md); the domain stays the public seam
  defdelegate ensure_wallet(org), to: Operations.EnsureWallet, as: :call

  defdelegate grant_credits(target, amount_cents, opts \\ []),
    to: Operations.GrantCredits,
    as: :call

  defdelegate credit_wallet(target, amount_cents, opts \\ []),
    to: Operations.CreditWallet,
    as: :call

  defdelegate debit_wallet(target, amount_micro_cents, opts \\ []),
    to: Operations.DebitWallet,
    as: :call

  defdelegate reverse_entry(entry, opts \\ []), to: Operations.ReverseEntry, as: :call

  defdelegate balance(wallet, opts \\ []), to: Operations.ReadBalance, as: :call

  defdelegate compute_runway(wallet), to: Operations.ComputeRunway, as: :call

  defdelegate sweep_zero_balance(wallet), to: Operations.SweepZeroBalance, as: :call

  # ADR-0029 Am. 3 gate 3: the quarterly per-country tax summary — the
  # return is a query over the ledger's persisted tax fields, never a
  # reconstruction.
  defdelegate tax_summary(from, to, opts \\ []), to: Operations.TaxSummary, as: :call

  # M6 (#136): the checkout seams — top-ups open, complete, and fail
  # through gateway-verified facts only (ADR-0029).
  defdelegate start_topup(org, params, opts \\ []),
    to: Operations.StartTopup,
    as: :call

  defdelegate complete_topup(outcome), to: Operations.CompleteTopup, as: :call

  defdelegate fail_topup(payment_request_id), to: Operations.FailTopup, as: :call

  # M6 (#137): the Confirmation step's reconciliation — same credit
  # path as the webhook, promptness only.
  defdelegate reconcile_topup(payment_request_id), to: Operations.ReconcileTopup, as: :call
end
