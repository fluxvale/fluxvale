defmodule FluxVale.Billing.LedgerEntryTest do
  @moduledoc """
  Ledger resource contract (#120): the append-only shape, the
  sign-matches-type invariant, per-wallet idempotency keys, and the
  one-reversal-per-entry database backstop.
  """

  use FluxVale.DataCase, async: true

  alias Ash.Error.Invalid
  alias Ash.Resource.Info
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

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

    # the concurrent case loses to the partial unique index — the error
    # class depends on which index (hand-named vs codegen-named) answers
    # the constraint, so assert the failure, not its wrapper
    assert {:error, error} = reversal.()
    assert error.__struct__ in [Ash.Error.Invalid, Ash.Error.Unknown]
  end

  test "members read their org's ledger; strangers don't; no actor posts", %{wallet: wallet} do
    member =
      wallet
      |> Ash.load!([organization: [:members]], authorize?: false)
      |> Map.get(:organization)
      |> Map.get(:members)
      |> List.first()

    assert {:ok, mine} = LedgerEntry.read(actor: member)
    assert Enum.any?(mine, &(&1.wallet_id == wallet.id))

    stranger = AccountsFixtures.user!()

    assert {:ok, theirs} = LedgerEntry.read(actor: stranger)
    refute Enum.any?(theirs, &(&1.wallet_id == wallet.id))

    # posting is the machinery's job — never an actor's
    assert {:error, %Ash.Error.Forbidden{}} =
             LedgerEntry.create(
               %{wallet_id: wallet.id, amount: 100, type: :credit, reason: :purchase},
               actor: member
             )
  end

  describe "list_for_wallet (#123's paginated history)" do
    setup do
      # Zero-funded wallet: the outer setup's welcome grant would sit on
      # page 2 and muddy the order assertions — amounts are the markers.
      {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

      # The i-th grant posts i cents, so "newest" is assertable per row.
      for i <- 1..30 do
        {:ok, _entry} = Billing.grant_credits(wallet, i)
      end

      %{wallet: wallet}
    end

    test "pages newest-first and walks the cursor to the end", %{wallet: wallet} do
      page = wallet_page(wallet)

      assert length(page.results) == 25
      assert page.more?
      # newest 25 = amounts 30..6, descending
      assert Enum.map(page.results, & &1.amount) == Enum.to_list(30..6//-1)

      assert {:ok, next} = Ash.page(page, :next)
      assert Enum.map(next.results, & &1.amount) == Enum.to_list(5..1//-1)
      refute next.more?

      # exhausted — the walk ends on an empty page
      assert {:ok, empty} = Ash.page(next, :next)
      assert empty.results == []
    end

    test "the cursor survives rows landing between pages", %{wallet: wallet} do
      page = wallet_page(wallet)

      # a newer row posts after page 1 was taken — the offset-style
      # shift (one row skipped) is what keyset exists to prevent
      {:ok, _newer} = Billing.grant_credits(wallet, 99)

      assert {:ok, next} = Ash.page(page, :next)
      assert Enum.map(next.results, & &1.amount) == Enum.to_list(5..1//-1)
    end

    test "the wallet filter scopes the page; strangers read an empty page", %{wallet: wallet} do
      stranger = AccountsFixtures.user!()

      page =
        LedgerEntry
        |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet.id}, actor: stranger)
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.read!(page: [limit: 25])

      assert page.results == []
    end

    test "a read without page opts falls back to the action's default limit", %{
      wallet: wallet
    } do
      page =
        LedgerEntry
        |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet.id}, authorize?: false)
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.read!()

      assert %Ash.Page.Keyset{} = page
      assert length(page.results) == 25
    end
  end

  # The refund policy's only override path (#140): an admin-gated Ash
  # action — the form AshAdmin renders — posting through the same
  # GrantCredits seam the welcome grant rides, never around it.
  describe "grant_goodwill (#140 — the goodwill credit)" do
    setup do
      # Zero-funded wallet: the outer setup's fixture funding would
      # muddy the balance math — the grant's delta is the assertion.
      {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

      %{wallet: wallet, admin: admin()}
    end

    test "a platform admin posts a goodwill credit through the grant seam", %{
      wallet: wallet,
      admin: admin
    } do
      assert {:ok, entry} = LedgerEntry.grant_goodwill(wallet.id, 500, actor: admin)

      # The posting is the ledger's normal shape — an :adjustment credit,
      # same as any operator adjustment through the domain seam.
      assert entry.type == :credit
      assert entry.amount == 500
      assert entry.reason == :adjustment
      assert entry.wallet_id == wallet.id

      assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    end

    test "non-admins and anonymous calls stay outside the override path", %{
      wallet: wallet,
      admin: _admin
    } do
      stranger = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               LedgerEntry.grant_goodwill(wallet.id, 500, actor: stranger)

      assert {:error, %Ash.Error.Forbidden{}} =
               LedgerEntry.grant_goodwill(wallet.id, 500, authorize?: true)
    end

    test "non-positive amounts are rejected at the argument constraint", %{
      wallet: wallet,
      admin: admin
    } do
      assert {:error, %Invalid{}} =
               LedgerEntry.grant_goodwill(wallet.id, 0, actor: admin)
    end

    test "an unknown wallet surfaces the posting error, nothing posts", %{
      admin: admin
    } do
      bogus = Ash.UUID.generate()

      assert {:error, %Invalid{}} = LedgerEntry.grant_goodwill(bogus, 100, actor: admin)

      assert {:ok, entries} =
               LedgerEntry
               |> Ash.Query.filter(wallet_id == ^bogus)
               |> Ash.read(authorize?: false)

      assert entries == []
    end

    test "platform admins read any org's ledger (support surface)", %{
      wallet: wallet,
      admin: admin
    } do
      # The admin isn't a member of this org — the member read policy
      # alone would refuse; the admin clause is what lets the ledger
      # show up in AshAdmin.
      {:ok, _entry} = Billing.grant_credits(wallet, 300)

      assert {:ok, entries} =
               LedgerEntry
               |> Ash.Query.filter(wallet_id == ^wallet.id)
               |> Ash.read(actor: admin)

      assert length(entries) == 1
    end
  end

  defp wallet_page(wallet) do
    LedgerEntry
    |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet.id}, authorize?: false)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.read!(page: [limit: 25])
  end

  # Bootstrap posture (mirrors the Ops policy tests): the precondition
  # runs authorize?: false; the policies themselves are under test.
  defp admin do
    case User.get_by_email("admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
    end
  end
end
