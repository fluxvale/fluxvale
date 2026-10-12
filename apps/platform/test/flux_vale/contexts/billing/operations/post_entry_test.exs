defmodule FluxVale.Billing.Operations.PostEntryTest do
  @moduledoc """
  The internal posting seam's own contract (#120): direction derived from
  type (sign applied, never trusted from the caller) and the guard the
  posting operations rely on. Public callers go through
  grant/credit/debit/reverse — this module is domain-internal.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing.Operations.PostEntry
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)
    %{wallet: wallet}
  end

  test "applies the sign from type — a caller cannot invert a posting", %{wallet: wallet} do
    assert {:ok, credit} = PostEntry.call(wallet, :credit, 100, :adjustment)
    assert credit.amount == 100

    assert {:ok, debit} = PostEntry.call(wallet, :debit, 100, :adjustment)
    assert debit.amount == -100
  end

  test "rejects malformed posts loudly (the internal-caller contract)" do
    {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    assert_raise FunctionClauseError, fn ->
      PostEntry.call(wallet, :uncredit, 100, :adjustment)
    end

    assert_raise FunctionClauseError, fn ->
      PostEntry.call(wallet, :credit, -100, :adjustment)
    end

    assert_raise FunctionClauseError, fn ->
      PostEntry.call(wallet, :credit, 0, :adjustment)
    end
  end
end
