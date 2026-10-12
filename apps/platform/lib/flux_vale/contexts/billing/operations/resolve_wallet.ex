defmodule FluxVale.Billing.Operations.ResolveWallet do
  @moduledoc """
  Resolves the wallet to post against, accepting either the wallet itself
  or its organization (internal seam for the posting operations — callers
  holding an org get the wallet provisioned on demand, the v1
  ensure-then-post shape). System operation, `authorize?: false`.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Operations.EnsureWallet
  alias FluxVale.Billing.Wallet

  @spec call(Wallet.t() | Organization.t()) :: {:ok, Wallet.t()} | {:error, term()}
  def call(%Wallet{} = wallet), do: {:ok, wallet}
  def call(%Organization{} = org), do: EnsureWallet.call(org)
end
