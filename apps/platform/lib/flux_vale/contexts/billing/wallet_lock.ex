defmodule FluxVale.Billing.WalletLock do
  @moduledoc """
  The wallet's transaction-scoped advisory lock — the serialization
  point every money writer takes before it re-reads the balance
  (settles, debit, reverse, the zero-balance sweep).

  Call it inside `FluxVale.Repo.transaction/1`, after the wallet is
  resolved and before the fresh read. The lock releases on commit or
  rollback and is reentrant within the same transaction, so a settle
  that calls `DebitWallet` does not deadlock on its own lock.

  The key is `hashtext/1` of the wallet uuid. A hash collision between
  two wallets would only over-serialize them, never mis-account: the
  balance always reads from the ledger under the lock.
  """

  alias FluxVale.Billing.Wallet

  @doc """
  Takes the wallet's advisory xact lock. `:ok` on success; raises on a
  DB failure (the caller's transaction rolls back).
  """
  @spec acquire(Wallet.t()) :: :ok
  def acquire(%Wallet{id: id}) do
    FluxVale.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [id])
    :ok
  end
end
