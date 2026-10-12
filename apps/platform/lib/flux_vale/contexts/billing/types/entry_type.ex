defmodule FluxVale.Billing.Types.EntryType do
  @moduledoc """
  Ledger entry direction (v1's credit/uncredit, renamed to match the
  operation verbs).

  - `:credit` — adds to the wallet balance (issuance: welcome, purchase,
    a reversal of a debit).
  - `:debit` — removes from the wallet balance (consumption: usage, a
    refund of remaining credits).
  """

  use Ash.Type.Enum, values: [:credit, :debit]
end
