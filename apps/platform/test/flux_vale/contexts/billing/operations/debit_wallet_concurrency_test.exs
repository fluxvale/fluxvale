defmodule FluxVale.Billing.Operations.DebitWalletConcurrencyTest do
  @moduledoc """
  The advisory lock's serialization proof (#120's exit criterion:
  "concurrent settle under the advisory lock").

  Two real connections post against one wallet concurrently. Whichever
  acquires the lock first commits its carryover write; the loser re-reads
  under the lock and posts the pooled whole cent. The final state is
  deterministic — a lost carryover update would leave 7_500µ pooled
  instead of the correct 5_000µ.

  Uses `Sandbox.checkout(_, sandbox: false)` connections: the rows must
  be committed for both writers to see them. The test cleans up its own
  committed rows (by id) before finishing.
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Billing
  alias FluxVale.Repo
  alias FluxVale.TestSupport.BillingFixtures

  @debit_micro 7_500

  test "concurrent debits pool their fractions — no lost carryover update" do
    %{wallet: wallet, user_id: user_id} = seeded!()

    # The rows are committed outside the sandbox — cleanup runs in
    # on_exit so a failure mid-test never strands them in the shared DB.
    on_exit(fn -> cleanup!(user_id) end)

    parent = self()

    workers =
      for name <- [:a, :b] do
        spawn(fn ->
          conn = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, name})

          result =
            receive do
              :go -> Billing.debit_wallet(wallet, @debit_micro)
            end

          Sandbox.checkin(Repo, conn)
          send(parent, {:done, name, result})
        end)
      end

    # both writers hold real connections before either posts, so the
    # lock contention is genuine, not a race we happen to win
    Enum.each(1..2, fn _round -> assert_receive {:ready, _name}, 5_000 end)
    Enum.each(workers, fn pid -> send(pid, :go) end)

    assert_receive {:done, _first, first_result}, 5_000
    assert_receive {:done, _second, second_result}, 5_000
    assert {:ok, first} = first_result
    assert {:ok, second} = second_result

    # one writer's 7_500µ is sub-cent (no ledger row); the other's pools
    # with it and posts the whole cent
    outcomes = [first, second]

    assert Enum.count(outcomes, &(&1 == :accrued)) == 1
    assert Enum.any?(outcomes, &match?(%{amount: -1}, &1))

    # deterministic final state: one cent posted, half a cent pooled —
    # the lost-update signature would be carryover 7_500 with no posting
    assert committed?(fn ->
             fresh = Repo.reload!(wallet)

             assert fresh.carryover == 5_000

             assert {:ok, balance} = Billing.balance(fresh, authorize?: false)
             assert balance == 9_999
           end)
  end

  # Seeds the wallet through a committed (non-sandboxed) connection so
  # both writers can see it; returns the ids the cleanup needs.
  defp seeded! do
    committed?(fn ->
      {org, owner} = BillingFixtures.grant_free_org!()

      {_org, wallet} = BillingFixtures.funded_wallet!(org: org, balance_cents: 10_000)

      %{wallet: wallet, user_id: owner.id}
    end)
  end

  # Runs fun on a real connection whose writes commit immediately. Works
  # from on_exit too — sandbox:false checkouts bypass sandbox ownership.
  defp committed?(fun) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Removes the committed rows — the sandbox never owned them. Scoped by
  # the owner's memberships: every org here (the seeded fixture and, since
  # #122, the user's own JIT personal org with its welcome-granted wallet)
  # goes with the user. Raw SQL params need uuids as 16-byte binaries
  # (Ecto.UUID.dump!/1).
  defp cleanup!(user_id) do
    committed?(fn ->
      user_id = Ecto.UUID.dump!(user_id)

      result =
        Repo.query!("SELECT organization_id FROM memberships WHERE user_id = $1", [user_id])

      org_ids = Map.get(result, :rows)

      Repo.query!(
        "DELETE FROM billing_ledger_entries WHERE wallet_id IN (SELECT id FROM billing_wallets WHERE organization_id = ANY($1))",
        [org_ids]
      )

      Repo.query!("DELETE FROM billing_wallets WHERE organization_id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM memberships WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    end)
  end
end
