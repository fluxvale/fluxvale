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
  be committed for the second run to see it. The test cleans up its own
  committed row before finishing.
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Repo

  # CLUSTER_NAME is VM-global, so both workers run the same name — the
  # variant the unique index would reject without the lock.
  @cluster_name "concurrency-bringup-01"

  test "two concurrent runs leave exactly one row, no raise" do
    original = System.get_env("CLUSTER_NAME")
    System.put_env("CLUSTER_NAME", @cluster_name)

    on_exit(fn ->
      case original do
        nil -> System.delete_env("CLUSTER_NAME")
        value -> System.put_env("CLUSTER_NAME", value)
      end
    end)

    # Defensive: the committed row this test writes must never survive a
    # failure mid-test (other suites use the sandbox; this one doesn't).
    on_exit(fn ->
      delete_committed!(fn -> Cluster.get_by_name(@cluster_name, authorize?: false) end)
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

  # Runs fun on a real connection whose writes commit immediately.
  defp committed(fun) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Removes the committed row — the sandbox never owned it.
  defp delete_committed!(lookup) do
    committed(fn ->
      case lookup.() do
        {:ok, cluster} -> Repo.delete!(cluster)
        {:error, _not_found} -> :ok
      end
    end)
  end
end
