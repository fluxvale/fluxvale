defmodule FluxVale.Billing.Operations.ReadBalanceTest do
  @moduledoc "Balance reads (#120): the live aggregate, authorization propagated."

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  test "reads the live ledger sum; zero is never nil" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "an org member may read; a stranger may not" do
    {org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 4_00)

    member =
      org
      |> Ash.load!(:members, authorize?: false)
      |> Map.get(:members)
      |> List.first()

    assert {:ok, 4_00} = Billing.balance(wallet, actor: member)

    stranger = AccountsFixtures.user!()

    # read policies filter to nothing — the wrapped NotFound shape (v1's
    # known Ash behavior), indistinguishable from a nonexistent wallet
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Billing.balance(wallet, actor: stranger)
  end
end
