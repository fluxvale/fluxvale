defmodule FluxVale.Identity.UserEmail.GuardConcurrencyTest do
  @moduledoc """
  The decoy-lock concurrency proof (identity lane #285): two removes of
  a user's LAST TWO verified rows, both structs pointing the FOR UPDATE
  lock at a decoy account. A lock target taken from the caller's struct
  lets both removes pass the last-verified guard (each sees the other's
  row as "the remaining verified one"); the fixed guard locks the fresh
  row's user, serializes on it, and exactly one remove can succeed.

  Uses `Sandbox.checkout(_, sandbox: false)` connections: the rows must
  be committed for both removers to see them. The test cleans up its own
  committed rows (in on_exit, so a failure mid-test never strands them
  in the shared DB).
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Repo

  require Ash.Query

  test "concurrent decoy removes cannot empty the account's verified set" do
    %{owner: owner, decoy_a: decoy_a, decoy_b: decoy_b, rows: [first, second]} = seeded!()

    # The rows are committed outside the sandbox — cleanup runs in
    # on_exit so a failure mid-test never strands them in the shared DB.
    on_exit(fn -> cleanup!([owner.id, decoy_a.id, decoy_b.id]) end)

    parent = self()

    # Each worker forges its lock target to its OWN decoy account — the
    # decoys must NOT serialize the forged removes, or a lock-target
    # regression (locking changeset.data.user_id) would serialize on one
    # decoy row and pass this test while still allowing the
    # zero-verified violation in production.
    attacks = [
      {first, decoy_a.id},
      {second, decoy_b.id}
    ]

    workers =
      for {row, decoy_id} <- attacks do
        spawn(fn ->
          conn = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, self()})

          # the attack: the lock target rides the caller's struct
          forged = Map.put(row, :user_id, decoy_id)

          result =
            try do
              receive do
                :go -> UserEmail.remove(forged, actor: owner, authorize?: true)
              end
            after
              # a crash between checkout and checkin must not leak the
              # connection for the rest of the suite
              Sandbox.checkin(Repo, conn)
            end

          send(parent, {:done, self(), result})
        end)
      end

    # both removers hold real connections before either acts, so the
    # lock contention is genuine, not a race we happen to win
    Enum.each(workers, fn _worker -> assert_receive {:ready, _pid}, 5_000 end)
    Enum.each(workers, fn pid -> send(pid, :go) end)

    assert_receive {:done, _first_pid, first_result}, 5_000
    assert_receive {:done, _second_pid, second_result}, 5_000

    # exactly one remove succeeds; the loser hits the last-verified guard
    outcomes = [first_result, second_result]
    assert Enum.count(outcomes, &(&1 == :ok)) == 1
    assert Enum.count(outcomes, &match?({:error, _}, &1)) == 1

    # the invariant the decoy attack is after: never zero verified
    assert committed?(fn -> count_verified(owner.id) == 1 end)
  end

  # Seeds through a committed (non-sandboxed) connection so both removers
  # can see the rows; actions all run authorize?: false (preconditions —
  # there is no actor yet, mirroring the seeds).
  defp seeded! do
    committed?(fn ->
      unique = System.unique_integer([:positive])
      owner = User.create!("guard-cc-owner-#{unique}@fluxvale.test", %{}, authorize?: false)

      decoy_a = User.create!("guard-cc-decoy-a-#{unique}@fluxvale.test", %{}, authorize?: false)
      decoy_b = User.create!("guard-cc-decoy-b-#{unique}@fluxvale.test", %{}, authorize?: false)

      rows =
        for n <- 1..2 do
          address = "guard-cc-#{n}-#{unique}@fluxvale.test"
          {:ok, row} = UserEmail.add(address, %{user: owner}, authorize?: false)
          {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)
          Ash.get!(UserEmail, row.id, authorize?: false)
        end

      %{owner: owner, decoy_a: decoy_a, decoy_b: decoy_b, rows: rows}
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

  defp count_verified(user_id) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user_id and not is_nil(verified_at))
    |> Ash.count!(authorize?: false)
  end

  # Removes the committed rows — the sandbox never owned them. Both users
  # JIT-provisioned a personal org (with its welcome wallet), so the org
  # chain goes too. Raw SQL params need uuids as 16-byte binaries
  # (Ecto.UUID.dump!/1).
  defp cleanup!(user_ids) do
    committed?(fn ->
      dumped = Enum.map(user_ids, &Ecto.UUID.dump!/1)

      Repo.query!("DELETE FROM user_emails WHERE user_id = ANY($1)", [dumped])

      %{rows: org_rows} =
        Repo.query!(
          "SELECT organization_id FROM memberships WHERE user_id = ANY($1)",
          [dumped]
        )

      org_ids = Enum.map(org_rows, &hd/1)

      Repo.query!(
        "DELETE FROM billing_ledger_entries WHERE wallet_id IN (SELECT id FROM billing_wallets WHERE organization_id = ANY($1))",
        [org_ids]
      )

      Repo.query!("DELETE FROM billing_wallets WHERE organization_id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM memberships WHERE user_id = ANY($1)", [dumped])
      Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM users WHERE id = ANY($1)", [dumped])
    end)
  end
end
