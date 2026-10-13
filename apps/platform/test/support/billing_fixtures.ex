defmodule FluxVale.TestSupport.BillingFixtures do
  @moduledoc """
  Preconditions for Billing tests (#120): an org (its wallet provisioned
  on demand through `Billing.ensure_wallet/1`) funded through the posting
  operations — test data rides the actions, mirroring production callers.
  """

  alias FluxVale.Billing
  alias FluxVale.TestSupport.AccountsFixtures

  @doc """
  `{org, wallet}` with the wallet funded to `balance_cents` (default
  10_000¢) via a grant. Pass `org:` to reuse an org.
  """
  @spec funded_wallet!(keyword()) :: {FluxVale.Accounts.Organization.t(), Billing.Wallet.t()}
  def funded_wallet!(opts \\ []) do
    org =
      Keyword.get(opts, :org) ||
        AccountsFixtures.personal_org!(AccountsFixtures.user!())

    {:ok, wallet} = Billing.ensure_wallet(org)

    balance_cents = Keyword.get(opts, :balance_cents, 10_000)

    if balance_cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, balance_cents)
    end

    {org, wallet}
  end
end
