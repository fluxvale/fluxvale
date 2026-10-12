defmodule FluxVale.Billing.Operations.CreditWallet do
  @moduledoc """
  Posts externally funded `:credit` (reason `:purchase`) — the M6 payment
  webhook's posting surface (ADR-0029). Pass `idempotency_key:` derived
  from the payment id: a retried webhook replays to the same entry, never
  a double credit. System operation, `authorize?: false`.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Operations.PostEntry
  alias FluxVale.Billing.Operations.ResolveWallet
  alias FluxVale.Billing.Wallet

  @reason_default :purchase

  @spec call(Wallet.t() | Organization.t(), pos_integer(), keyword()) ::
          {:ok, LedgerEntry.t()} | {:error, term()}
  # defguard is a compile-time macro — the line never runs (cover artifact)
  # coveralls-ignore-next-line
  defguard is_positive(amount) when is_integer(amount) and amount > 0

  def call(target, amount_cents, opts \\ []) when is_positive(amount_cents) do
    with {:ok, wallet} <- ResolveWallet.call(target) do
      PostEntry.call(
        wallet,
        :credit,
        amount_cents,
        Keyword.get(opts, :reason, @reason_default),
        opts
      )
    end
  end
end
