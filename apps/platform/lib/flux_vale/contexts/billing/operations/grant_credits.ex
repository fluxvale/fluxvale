defmodule FluxVale.Billing.Operations.GrantCredits do
  @moduledoc """
  Posts a system-issued `:credit` — the welcome grant rides the
  org-creation transaction (#122); operator adjustments reuse the seam
  with `reason: :adjustment` (the funding dimension is what keeps the
  ledger reconcilable — see `EntryReason`). Keyless by default: the caller
  guarantees once-only (the provisioning flow's transactional post); pass
  `idempotency_key:` when the call site can retry. System operation,
  `authorize?: false`.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Operations.PostEntry
  alias FluxVale.Billing.Operations.ResolveWallet
  alias FluxVale.Billing.Wallet

  @reason_default :welcome

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
