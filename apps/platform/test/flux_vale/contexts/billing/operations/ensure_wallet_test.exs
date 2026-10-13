defmodule FluxVale.Billing.Operations.EnsureWalletTest do
  @moduledoc "Wallet provisioning (#120): idempotent get-or-create."

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.TestSupport.BillingFixtures

  test "creates a wallet for an org that has none" do
    # Grant-free org — JIT provisioning eagerly wallets + grants (#122),
    # so the create branch needs an org that truly has none.
    {org, _owner} = BillingFixtures.grant_free_org!()

    assert {:ok, wallet} = Billing.ensure_wallet(org)
    assert wallet.organization_id == org.id
    assert wallet.carryover == 0
  end

  test "is idempotent — the same wallet comes back" do
    {org, _owner} = BillingFixtures.grant_free_org!()

    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, again} = Billing.ensure_wallet(org)

    assert again.id == wallet.id
  end
end
