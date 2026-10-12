defmodule FluxVale.Billing.Types.EntryReason do
  @moduledoc """
  Funding dimension for a ledger entry — the source/sink of the credits
  (v1's enum, ported). This is what keeps the ledger reconcilable: every
  posting records where credits came from or went to.

  - `:welcome` — signup grant (#122 wires the call).
  - `:purchase` — credits bought via the payment gateway (M6).
  - `:usage` — flat-rate accrual consumption (#121 wires the call).
  - `:refund` — a reversal entry (remaining credits back to the payer).
  - `:adjustment` — manual/operational correction.
  """

  use Ash.Type.Enum, values: [:welcome, :purchase, :usage, :refund, :adjustment]
end
