defmodule FluxVale.Billing.Operations.EnsureWallet do
  @moduledoc """
  Ensures an organization has a wallet, creating one if none exists (#120).

  Idempotent: returns the existing wallet when the org already has one.
  The `unique_org` identity is the concurrent-race backstop — a lost race
  surfaces as an error rather than a second wallet. System operation
  (runs with `authorize?: false`): actors may read wallets, the billing
  machinery provisions them.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Wallet

  @spec call(Organization.t()) :: {:ok, Wallet.t()} | {:error, term()}
  def call(%Organization{} = org) do
    case Wallet.get_by_organization(org.id, authorize?: false) do
      {:ok, wallet} ->
        {:ok, wallet}

      # get? reads wrap NotFound inside Ash.Error.Invalid — a miss (the
      # realistic outcome) creates; any read failure also lands in the
      # create, which then fails loudly rather than mask it.
      {:error, _not_found_or_failed} ->
        Wallet.create(%{organization_id: org.id}, authorize?: false)
    end
  end
end
