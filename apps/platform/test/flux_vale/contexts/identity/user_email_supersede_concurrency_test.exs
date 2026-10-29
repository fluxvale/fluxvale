defmodule FluxVale.Identity.UserEmail.SupersedeConcurrencyTest do
  @moduledoc """
  The atomic supersede predicate under true concurrency (round-2
  verdict, "could not verify" #1): two separate DB connections, conn A
  flipping the row's `verified_at` inside an open transaction (holding
  the row lock), conn B running the supersede — its DELETE blocks on
  the lock — then A commits. Under READ COMMITTED the blocked DELETE
  re-evaluates its WHERE against the row's newest committed version:
  `is_nil(verified_at)` no longer matches and the verified row MUST
  survive (the read-then-remove shape the P2-1 fix replaced deleted it).

  Synchronization is lock ordering, not timing — no sleeps, no
  retry-until-green:

  * A's UPDATE commits to the lock before B is ever armed (`{:locked_a}`
    is received before the `:go` to B), so B can never legitimately
    delete the row as pending;
  * B can only report `{:done_b, :ok}` after A has committed (blocked
    ordering) or after having run entirely past the commit (unblocked
    ordering, if scheduling delays B) — the asserted invariant, the
    verified row survives, holds in both orderings;
  * the assertion pairs survival WITH `verified_at != nil`, so a flip
    that failed to commit cannot fake a pass.
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Repo

  require Ash.Query

  @receive_timeout 5_000

  test "a supersede racing a concurrent verify keeps the verified row — the predicate re-evaluates at delete time" do
    %{owner: owner, row: row, address: address} = seeded!()

    # the rows are committed outside the sandbox — cleanup runs in
    # on_exit so a failure mid-test never strands them in the shared DB
    on_exit(fn -> cleanup!([owner.id]) end)

    parent = self()

    # conn A: flip verified_at inside an OPEN transaction — the row
    # lock is held, the flip invisible, until this process is told to
    # commit
    flipper =
      spawn(fn ->
        conn = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.transaction(fn ->
            Repo.query!("UPDATE user_emails SET verified_at = $1 WHERE id = $2", [
              DateTime.utc_now(:second),
              Ecto.UUID.dump!(row.id)
            ])

            send(parent, {:locked_a, self()})

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:never_told_to_commit)
            end
          end)

          send(parent, {:committed_a, self()})
        after
          Sandbox.checkin(Repo, conn)
        end
      end)

    # conn B: runs the production supersede seam — its DELETE blocks on
    # the lock A holds until A commits (the pid arrives with {:ready_b})
    spawn(fn ->
      conn = Sandbox.checkout(Repo, sandbox: false)

      try do
        send(parent, {:ready_b, self()})

        receive do
          :go -> send(parent, {:done_b, UserEmail.supersede_pending_claims(address)})
        after
          10_000 -> send(parent, {:done_b, :never_armed})
        end
      after
        Sandbox.checkin(Repo, conn)
      end
    end)

    # order: the flip holds the lock, THEN the supersede is armed —
    # the DELETE can never see the row as (still) pending-and-deletable
    # in a way that predates the flip's lock
    assert_receive {:locked_a, _}, @receive_timeout
    assert_receive {:ready_b, runner_pid}, @receive_timeout
    send(runner_pid, :go)
    send(flipper, :commit)

    assert_receive {:done_b, :ok}, @receive_timeout
    assert_receive {:committed_a, _}, @receive_timeout

    # THE assertion, and it must be read as a pair: the row survived
    # AND it is verified — survival of a still-pending row would mean
    # the flip never committed (a trivial pass), not that the
    # re-evaluation excluded it
    assert [
             %UserEmail{user_id: owner_id, verified_at: verified_at, is_primary: false} = survived
           ] = rows_for(address)

    assert owner_id == owner.id
    refute is_nil(verified_at)
    assert survived.id == row.id
  end

  # Seeds through a committed (non-sandboxed) connection so both racing
  # connections see the rows. The owner rides `Ash.Seed.seed!` — a state
  # actions cannot produce is not the point here, but it keeps the
  # committed footprint to user_emails + users (no org chain to clean).
  # The claim rides the resource's own :add action (authorize?: false —
  # precondition posture, mirroring the seeds).
  defp seeded! do
    committed?(fn ->
      unique = System.unique_integer([:positive])
      address = "supersede-cc-#{unique}@fluxvale.test"

      owner = Ash.Seed.seed!(User, %{email: "supersede-cc-owner-#{unique}@fluxvale.test"})
      {:ok, row} = UserEmail.add(address, %{user: owner}, authorize?: false)
      row = Ash.get!(UserEmail, row.id, authorize?: false)

      %{owner: owner, row: row, address: address}
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

  defp rows_for(address) do
    UserEmail
    |> Ash.Query.filter(address == ^address)
    |> Ash.read!(authorize?: false)
  end

  # Removes the committed rows — the sandbox never owned them. The seed!
  # owner provisioned no org, so the chain stops at users.
  defp cleanup!(user_ids) do
    committed?(fn ->
      dumped = Enum.map(user_ids, &Ecto.UUID.dump!/1)

      Repo.query!("DELETE FROM user_emails WHERE user_id = ANY($1)", [dumped])
      Repo.query!("DELETE FROM users WHERE id = ANY($1)", [dumped])
    end)
  end
end
