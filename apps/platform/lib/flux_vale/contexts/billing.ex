defmodule FluxVale.Billing do
  @moduledoc """
  Billing: wallets and the append-only ledger (#120, ADR-0028 §3) — the
  settlement core every other billing lane attaches to.

  Prepaid credits are integer US cents; the ledger only ever carries
  whole cents, and flat-rate accrual fractions pool per-wallet in
  `Wallet.carryover` (micro-cents). Refunds are compensating entries
  (`reverse_entry/2`), never row mutations (ADR-0029). Postings run
  `authorize?: false` — the operations are the system seam; actors read
  their org's wallet and ledger through the policies.
  """

  use Ash.Domain, otp_app: :flux_vale

  alias FluxVale.Billing.Operations

  resources do
    resource FluxVale.Billing.LedgerEntry
    resource FluxVale.Billing.Wallet
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
end
