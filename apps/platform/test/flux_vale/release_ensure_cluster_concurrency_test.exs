defmodule FluxVale.Release.EnsureClusterConcurrencyTest do
  @moduledoc """
  The advisory lock's serialization proof for `ensure_cluster/0` (#172):
  two real connections run the task against an empty clusters table at
  once. Only the lock holder reads-and-inserts; the loser blocks until
  the winner commits, then re-reads *under the lock* and finds the row —
  both runs return `:ok` and the table holds exactly one row.

  Without the lock both would read empty and insert: the loser would hit
  the unique-name index and raise (the same-name shape) or, under a
  different name, land a second row that breaks `ResolveCluster`.

  Uses `Sandbox.checkout(_, sandbox: false)` connections — the row must
  be committed for the second run to see it. Those commits are real
  writes to the shared test DB, so this module sweeps every
  `concurrency-*` row before and after itself: a run that dies between
  commit and cleanup would otherwise strand a row that breaks the
  exactly-one-cluster invariant for every later suite on this DB
  (read committed sees it from inside any sandbox — #241).
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Repo

  # CLUSTER_NAME is VM-global, so both workers run the same name — the
  # variant the unique index would reject without the lock.
  @cluster_name "concurrency-bringup-01"

  # #241: self-heal any stranded committed row (this module is the only
  # writer of `concurrency-*` rows) before the tests read the table, and
  # again after — including when a test body fails mid-run.
  setup do
    sweep_committed!()
    on_exit(fn -> sweep_committed!() end)
    :ok
  end

  test "two concurrent runs leave exactly one row, no raise" do
    original = System.get_env("CLUSTER_NAME")
    System.put_env("CLUSTER_NAME", @cluster_name)

    on_exit(fn ->
      case original do
        nil -> System.delete_env("CLUSTER_NAME")
        value -> System.put_env("CLUSTER_NAME", value)
      end
    end)

    parent = self()

    workers =
      for name <- [:a, :b] do
        spawn(fn ->
          conn = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, name})

          result =
            receive do
              :go -> FluxVale.Release.ensure_cluster()
            end

          Sandbox.checkin(Repo, conn)
          send(parent, {:done, name, result})
        end)
      end

    # Both writers hold real connections before either runs, so the lock
    # contention is genuine, not a race we happen to win.
    Enum.each(1..2, fn _round -> assert_receive {:ready, _name}, 5_000 end)
    Enum.each(workers, fn pid -> send(pid, :go) end)

    assert_receive {:done, _first, first_result}, 5_000
    assert_receive {:done, _second, second_result}, 5_000
    assert first_result == :ok
    assert second_result == :ok

    # Exactly one row, regardless of which run created it.
    assert {:ok, [%{name: @cluster_name}]} =
             committed(fn -> Ash.read(Cluster, authorize?: false) end)
  end

  # The arm that actually protects ResolveCluster: a run whose name
  # differs from the row another run is creating must raise, not land a
  # second row. Deterministic — a holder process keeps the advisory lock
  # (with its row inserted) until the moment the task tries to run, so
  # this is genuine contention, not a race we happen to win.
  test "a concurrent run under a different name raises, leaving one row" do
    original = System.get_env("CLUSTER_NAME")
    System.put_env("CLUSTER_NAME", "concurrency-other-01")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("CLUSTER_NAME")
        value -> System.put_env("CLUSTER_NAME", value)
      end
    end)

    parent = self()

    holder =
      spawn(fn ->
        conn = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["clusters"])

          # return_notifications? — keep the transaction quiet, same as
          # the task under test.
          Cluster
          |> Ash.Changeset.for_create(:create, %{name: "concurrency-holder-01"})
          |> Ash.create!(authorize?: false, return_notifications?: true)

          send(parent, :locked)

          receive do
            :commit -> :ok
          end
        end)

        Sandbox.checkin(Repo, conn)
        send(parent, :released)
      end)

    assert_receive :locked, 5_000

    spawn(fn ->
      conn = Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:runner_ready, backend_pid()})

      result =
        try do
          FluxVale.Release.ensure_cluster()
        rescue
          error -> {:raised, error}
        end

      Sandbox.checkin(Repo, conn)
      send(parent, {:done, result})
    end)

    # Wait until the runner is genuinely blocked on the advisory lock —
    # scoped to its own backend PID, not a global lock count — before
    # releasing the holder. Without this the holder could commit first
    # and the runner would read the committed row even with the lock
    # removed (verified: the test still passed without the lock).
    assert_receive {:runner_ready, runner_pid}, 5_000
    await_lock_waiter(runner_pid)

    send(holder, :commit)

    assert_receive :released, 5_000
    assert_receive {:done, {:raised, %RuntimeError{} = error}}, 5_000
    assert Exception.message(error) =~ ~r/already exists, not "concurrency-other-01"/

    assert {:ok, [%{name: "concurrency-holder-01"}]} =
             committed(fn -> Ash.read(Cluster, authorize?: false) end)
  end

  # The caller's own connection backend PID (distinct from the runner's).
  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Polls pg_locks for an ungranted advisory lock held by `pid` — proof
  # the runner reached the lock and is waiting, not merely about to.
  # Polls an external system (Postgres), so sleep is the tool.
  defp await_lock_waiter(pid, attempts_left \\ 100) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE pid = $1 AND locktype = 'advisory' AND NOT granted",
        [pid]
      )

    cond do
      waiting > 0 ->
        :ok

      attempts_left == 0 ->
        flunk("ensure_cluster/0 never blocked on the advisory lock")

      true ->
        Process.sleep(20)
        await_lock_waiter(pid, attempts_left - 1)
    end
  end

  # Runs fun on a real connection whose writes commit immediately.
  defp committed(fun) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # #241: removes every committed `concurrency-*` row — this module
  # owns the prefix, so a stray from this or a previous run can never
  # outlive it. Raw SQL matches the file's advisory-lock posture; the
  # sandbox never owned these rows.
  defp sweep_committed! do
    committed(fn ->
      Repo.query!("DELETE FROM clusters WHERE name LIKE 'concurrency-%'")
      :ok
    end)
  end
end
