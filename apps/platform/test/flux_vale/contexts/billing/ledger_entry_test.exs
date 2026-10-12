defmodule FluxVale.Billing.LedgerEntryTest do
  @moduledoc """
  Ledger resource contract (#120): the append-only shape, the
  sign-matches-type invariant, per-wallet idempotency keys, and the
  one-reversal-per-entry database backstop.
  """

  use FluxVale.DataCase, async: true

  alias Ash.Error.Invalid
  alias Ash.Resource.Info
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    {_org, wallet} = BillingFixtures.funded_wallet!()
    %{wallet: wallet}
  end

  test "the ledger is append-only — no update or destroy actions exist" do
    action_types =
      LedgerEntry
      |> Info.actions()
      |> MapSet.new(& &1.type)

    refute MapSet.member?(action_types, :update)
    refute MapSet.member?(action_types, :destroy)
  end

  test "rows never change — there is no updated_at" do
    refute Info.attribute(LedgerEntry, :updated_at)
  end

  test "credits must be positive, debits negative (SignMatchesType)", %{wallet: wallet} do
    assert {:error, %Invalid{errors: errors}} =
             LedgerEntry.create(
               %{wallet_id: wallet.id, amount: -100, type: :credit, reason: :purchase},
               authorize?: false
             )

    assert Enum.any?(errors, &(&1.message == "sign must match type"))

    assert {:error, %Invalid{errors: errors}} =
             LedgerEntry.create(
               %{wallet_id: wallet.id, amount: 100, type: :debit, reason: :usage},
               authorize?: false
             )

    assert Enum.any?(errors, &(&1.message == "sign must match type"))

    # a missing amount trips the same invariant (the validation runs on
    # what's there — nil matches neither arm)
    assert {:error, %Invalid{errors: errors}} =
             LedgerEntry.create(
               %{wallet_id: wallet.id, type: :credit, reason: :purchase},
               authorize?: false
             )

    assert Enum.any?(errors, &(&1.message == "sign must match type"))

    # the aligned pairs insert cleanly
    assert {:ok, _entry} =
             LedgerEntry.create(
               %{wallet_id: wallet.id, amount: 100, type: :credit, reason: :purchase},
               authorize?: false
             )

    assert {:ok, _entry} =
             LedgerEntry.create(
               %{wallet_id: wallet.id, amount: -100, type: :debit, reason: :usage},
               authorize?: false
             )
  end

  test "idempotency keys are unique per wallet; NULL keys stay distinct", %{wallet: wallet} do
    assert {:ok, entry} =
             LedgerEntry.create(
               %{
                 wallet_id: wallet.id,
                 amount: 100,
                 type: :credit,
                 reason: :purchase,
                 idempotency_key: "pay_1"
               },
               authorize?: false
             )

    assert {:error, %Invalid{}} =
             LedgerEntry.create(
               %{
                 wallet_id: wallet.id,
                 amount: 100,
                 type: :credit,
                 reason: :purchase,
                 idempotency_key: "pay_1"
               },
               authorize?: false
             )

    # the same key on a different wallet is a different post
    {other_org, other_wallet} = BillingFixtures.funded_wallet!()

    assert {:ok, other_entry} =
             LedgerEntry.create(
               %{
                 wallet_id: other_wallet.id,
                 amount: 100,
                 type: :credit,
                 reason: :purchase,
                 idempotency_key: "pay_1"
               },
               authorize?: false
             )

    assert other_entry.wallet_id != entry.wallet_id
    assert other_org.id != other_wallet.id
  end

  test "one reversal per entry — the partial unique index is the backstop", %{wallet: wallet} do
    {:ok, original} =
      LedgerEntry.create(
        %{wallet_id: wallet.id, amount: 100, type: :credit, reason: :purchase},
        authorize?: false
      )

    reversal = fn ->
      LedgerEntry.create(
        %{
          wallet_id: wallet.id,
          amount: -100,
          type: :debit,
          reason: :refund,
          reverses_id: original.id
        },
        authorize?: false
      )
    end

    assert {:ok, _first} = reversal.()

    # the concurrent case loses to the partial unique index (an Unknown
    # wrapping the constraint violation, not the guard's Invalid)
    assert {:error, %Ash.Error.Unknown{}} = reversal.()
  end
end
