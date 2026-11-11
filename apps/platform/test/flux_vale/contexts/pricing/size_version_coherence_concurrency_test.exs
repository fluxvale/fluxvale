defmodule FluxVale.Pricing.SizeVersionCoherenceConcurrencyTest do
  @moduledoc """
  #543's fork proof, made deterministic: a size reallocation (T1)
  racing a version re-point (T2) must never leave a version whose
  compute defaults disagree with its recommended size — the fork #125
  exists to prevent. Both writers go through the real actions.

  The interleaving is sequenced by observation, not timing assertions:
  a gate connection holds the size row's FOR UPDATE lock first, so T1
  parks at exactly the statement the race lives around — pre-fix its
  UPDATE, after its unlocked probe; post-fix the probe's own lock. T2
  parks behind the same row either way (post-fix its locked read;
  pre-fix the FK's key-share on the size). Releasing the gate settles
  both writes in whatever grant order Postgres picks; the verdict is
  order-independent, so the assertions hold under every interleaving.
  Parks are observed in `pg_stat_activity` (a bounded poll loop is the
  observation mechanism, converging on a stable state — the assertions
  themselves are on settled rows and lock-manager state, never on a
  clock window; #586's discipline). The suite pins the fix in layers,
  all read from `pg_locks` — `pg_stat_activity.query` lags a statement
  under pipelining (observed on CI), so the parked statement is
  identified by its lock footprint instead: the race test proves the
  invariant end-to-end (failing pre-fix with the fork), the freeze
  test proves the probe parks at a locked read of its own row (a
  locked SELECT holds the relation under RowShareLock; a lock-less
  probe parks at the UPDATE under RowExclusiveLock), and the
  write-parked tests prove the version side holds a granted FOR SHARE
  on the size row at its own write — placement (`before_action?`) and
  mode together.

  Uses `Sandbox.checkout(_, sandbox: false)` connections (the
  DebitWalletConcurrency posture): T2's commit must be visible to T1's
  probe for the contention to be genuine. The test cleans up its own
  committed rows before finishing.
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Pricing.Size
  alias FluxVale.Repo
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures

  @poll_interval_ms 50
  @park_budget_polls 200

  # This module is the only suite writer that commits catalog/pricing
  # rows outside the sandbox, and a crash-era run once stranded some:
  # `System.unique_integer` restarts per BEAM, so a strand can collide
  # with a later run's fixture slugs. Sweep before/after (#241's
  # concurrency posture — strands self-heal instead of flaking the
  # next run).
  setup do
    sweep!()
    :ok
  end

  test "a size reallocation and a version re-point cannot fork the pair" do
    %{version: version, from_id: from_id, target: target} = seeded!()

    t1 =
      spawn_worker(:t1, fn ->
        Size.update(target, %{cpu_cores: Decimal.new("1"), memory_mb: 1024}, authorize?: false)
      end)

    t2 =
      spawn_worker(:t2, fn ->
        AppVersion.update(
          version,
          %{
            recommended_size_id: target.id,
            default_cpu_cores: Decimal.new("0.5"),
            default_memory_mb: 256
          },
          authorize?: false
        )
      end)

    gate = start_gate!(target.id)

    # The gate dies first on cleanup: it is the lock the cleanup
    # DELETEs must pass through, and a failure path leaves it parked.
    on_exit(fn ->
      kill_if_alive(gate)
      kill_if_alive(t1)
      kill_if_alive(t2)
      cleanup!(version.id, from_id, target.id)
    end)

    assert_receive :gate_held, 5_000

    # T1 first: it queues on the gate before T2 starts, so the trace
    # reads as two operators racing on one size row.
    {:backend, :t1, t1_backend} = release_and_await!(t1, :t1)
    wait_until_parked!(t1_backend, "T1 (size reallocation)")

    {:backend, :t2, t2_backend} = release_and_await!(t2, :t2)
    wait_until_parked!(t2_backend, "T2 (version re-point)")

    send(gate, :release)

    assert_receive {:t1, t1_result}, 15_000
    assert_receive {:t2, t2_result}, 15_000

    # The invariant first: whatever interleaving Postgres picks, the
    # committed pair stays coherent. Pre-fix both writes commit and
    # the version's blueprint silently forks from the size envelope.
    assert committed_pair_coherent!(version.id),
           "fork landed: the version's defaults disagree with its size"

    # Serial interleavings are safe; the race must cost exactly one
    # write — the loser re-checked against committed state and lost.
    results = [t1_result, t2_result]

    assert Enum.count(results, &match?({:ok, _survivor}, &1)) == 1,
           "expected exactly one survivor, got: #{inspect(results)}"

    loser =
      Enum.find_value(results, fn
        {:ok, _survivor} -> nil
        {:error, error} -> Exception.message(error)
      end)

    assert loser =~ "compute is frozen" or loser =~ "must match",
           "unexpected rejection: #{loser}"
  end

  describe "each half of the fix parks on the size row lock (#543)" do
    # Parked statements are identified by their pg_locks footprint,
    # not pg_stat_activity.query — the text lags a statement when
    # Postgrex pipelines (observed on CI: a worker parked mid-action
    # displaying "BEGIN"), so only the lock manager is trusted.

    test "the freeze probe parks at a locked read of its own row" do
      %{version: version, from_id: from_id, target: target} = seeded!()

      t =
        spawn_worker(:freeze, fn ->
          Size.update(target, %{cpu_cores: Decimal.new("1"), memory_mb: 1024}, authorize?: false)
        end)

      gate = start_gate!(target.id)

      on_exit(fn ->
        kill_if_alive(gate)
        kill_if_alive(t)
        cleanup!(version.id, from_id, target.id)
      end)

      assert_receive :gate_held, 5_000
      {:backend, :freeze, backend} = release_and_await!(t, :freeze)

      wait_until_parked!(backend, "size reallocation")

      # A locked SELECT holds the relation under RowShareLock; an
      # UPDATE (where a lock-less validation would park — its probe
      # already done) holds RowExclusiveLock. RowShareLock parked ==
      # the probe is gated behind its own row lock.
      assert relation_lock_mode!(backend, "pricing_sizes") == "RowShareLock"

      send(gate, :release)
      assert_receive {:freeze, {:ok, moved}}, 15_000
      assert Decimal.eq?(moved.cpu_cores, Decimal.new("1"))
    end

    # One setup, two proofs. Gating the version ROW parks the writer
    # at its own UPDATE — past the validation. While parked there:
    # the relation lock still held on pricing_sizes is the placement
    # proof (a changeset-time validation released it at statement
    # end), and the granted tuple lock's mode is the shape proof —
    # ShareLock is FOR SHARE; FOR UPDATE would read ExclusiveLock.
    test "a re-point holds a FOR SHARE on the size row across its write" do
      %{version: version, from_id: from_id, target: target} = seeded!()

      t =
        spawn_worker(:repoint, fn ->
          AppVersion.update(
            version,
            %{
              recommended_size_id: target.id,
              default_cpu_cores: Decimal.new("0.5"),
              default_memory_mb: 256
            },
            authorize?: false
          )
        end)

      gate = start_gate!(version.id, table: "app_versions")

      on_exit(fn ->
        kill_if_alive(gate)
        kill_if_alive(t)
        cleanup!(version.id, from_id, target.id)
      end)

      assert_receive :gate_held, 5_000
      {:backend, :repoint, backend} = release_and_await!(t, :repoint)

      wait_until_parked!(backend, "version write")

      assert relation_lock_mode!(backend, "pricing_sizes") == "RowShareLock"
      assert share_challenge_succeeds!(target.id)

      send(gate, :release)
      assert_receive {:repoint, {:ok, _moved}}, 15_000
    end

    # Same proof on the create path: the app row's FK check parks the
    # INSERT with the validation's share already held.
    test "a create holds a FOR SHARE on the size row across its write" do
      %{version: version, from_id: from_id, target: target} = seeded!()

      t =
        spawn_worker(:create, fn ->
          AppVersion.create(
            %{
              # :positive + rem — the grammar (#700) rejects negative
              # patches and patches beyond 6 digits, both of which a
              # bare unique_integer can print.
              version: "2.0.#{rem(System.unique_integer([:positive]), 1000)}",
              image: "registry.example.com/app:2.0",
              port: 3000,
              default_cpu_cores: Decimal.new("0.5"),
              default_memory_mb: 256,
              app_id: version.app_id,
              recommended_size_id: target.id
            },
            authorize?: false
          )
        end)

      gate = start_gate!(version.app_id, table: "apps")

      on_exit(fn ->
        kill_if_alive(gate)
        kill_if_alive(t)
        cleanup!(version.id, from_id, target.id, extra_for_app: version.app_id)
      end)

      assert_receive :gate_held, 5_000
      {:backend, :create, backend} = release_and_await!(t, :create)

      wait_until_parked!(backend, "version insert")

      assert relation_lock_mode!(backend, "pricing_sizes") == "RowShareLock"
      assert share_challenge_succeeds!(target.id)

      send(gate, :release)
      assert_receive {:create, {:ok, _created}}, 15_000
    end
  end

  # The gate: one connection holding a gated row FOR UPDATE in an
  # open transaction, parked until released. Defaults to the size row;
  # `table:` gates the version/app rows for the placement proofs.
  defp start_gate!(row_id, opts \\ []) do
    table = Keyword.get(opts, :table, "pricing_sizes")
    parent = self()

    spawn(fn ->
      conn = Sandbox.checkout(Repo, sandbox: false)

      Repo.transaction(fn ->
        row_uuid = Ecto.UUID.dump!(row_id)

        Repo.query!("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [row_uuid])
        send(parent, :gate_held)

        receive do
          :release -> :ok
        end
      end)

      Sandbox.checkin(Repo, conn)
    end)
  end

  # A writer on its own real connection, gated by :go so the test can
  # sequence the racers; reports its DB backend pid first (the action
  # runs on the connection this process checked out).
  defp spawn_worker(label, fun) do
    parent = self()

    spawn(fn ->
      conn = Sandbox.checkout(Repo, sandbox: false)

      try do
        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:backend, label, backend})

        receive do
          :go -> :ok
        end

        send(parent, {label, fun.()})
      after
        Sandbox.checkin(Repo, conn)
      end
    end)
  end

  # :go, then the worker's own backend announce — matched by label:
  # with two workers their announces can arrive in either order.
  defp release_and_await!(worker, label) do
    send(worker, :go)

    receive do
      {:backend, ^label, backend} -> {:backend, label, backend}
    after
      5_000 -> flunk("worker #{label} never announced its DB backend")
    end
  end

  # Parks are observed, not assumed: pg_stat_activity shows the
  # backend blocked on a lock (wait_event_type "Lock") once the worker
  # reaches the gated statement. Converges within a few polls; the
  # budget only bounds a bug (never parking) into a loud failure.
  defp wait_until_parked!(backend, label, polls_left \\ @park_budget_polls) do
    result = Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend])

    case result.rows do
      [["Lock"]] ->
        :ok

      _not_yet when polls_left > 1 ->
        Process.sleep(@poll_interval_ms)
        wait_until_parked!(backend, label, polls_left - 1)

      _never ->
        flunk("#{label} never parked on the size row lock")
    end
  end

  # A parked worker's abandoned checkout is reclaimed by DBConnection
  # on owner death, rolling its transaction back — safe to kill.
  defp kill_if_alive(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  # The backend's relation-level lock mode on `table` — the parked
  # statement's class. A locked SELECT holds RowShareLock; an
  # UPDATE/INSERT holds RowExclusiveLock. Nil when the transaction
  # holds no relation lock there (a changeset-time validation that
  # already released, or a lock-less validation).
  defp relation_lock_mode!(backend, table) do
    result =
      Repo.query!(
        "SELECT l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
          "WHERE l.pid = $1 AND l.locktype = 'relation' AND l.granted AND c.relname = $2",
        [backend, table]
      )

    case result.rows do
      [[mode]] -> mode
      [] -> nil
    end
  end

  # The mode proof by the conflict matrix itself (uncontended row
  # locks live in the heap tuple, invisible to pg_locks): while the
  # parked writer holds its size lock, a concurrent FOR SHARE NOWAIT
  # on the same row must SUCCEED — FOR SHARE is compatible with
  # itself. A FOR UPDATE regression answers lock_not_available. The
  # challenger acquires and releases on its own autocommit connection;
  # nothing is disturbed. The freeze side's own mode is not pinnable
  # this way (its validation parks before acquiring), but a weak
  # freeze lock forks the race test's interleaving.
  defp share_challenge_succeeds!(size_id) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      size_uuid = Ecto.UUID.dump!(size_id)

      result =
        Repo.query!("SELECT id FROM pricing_sizes WHERE id = $1 FOR SHARE NOWAIT", [size_uuid])

      [[_id]] = result.rows
      true
    rescue
      error in Postgrex.Error ->
        if error.postgres.code == :lock_not_available do
          false
        else
          reraise(error, __STACKTRACE__)
        end
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Seeds through the actions on a committed connection so both
  # writers see the rows: the fixture's version defaults (0.5/256)
  # match the target size's starting envelope, so the re-point is a
  # legal write against the state the reallocation changes.
  defp seeded! do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      version = InstanceFixtures.app_version!()

      try do
        target =
          PricingFixtures.size!(
            cpu_cores: Decimal.new("0.5"),
            memory_mb: 256,
            monthly_cents: 295
          )

        %{version: version, from_id: version.recommended_size_id, target: target}
      rescue
        # A fixture failing loudly (contract drift) already committed
        # the version's rows — don't strand them for want of a gate.
        error ->
          cleanup!(version.id, version.recommended_size_id, nil)
          reraise(error, __STACKTRACE__)
      end
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # The committed ground truth: the version row joined to whatever
  # size it points at after both writes settled.
  defp committed_pair_coherent!(version_id) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      version_uuid = Ecto.UUID.dump!(version_id)

      result =
        Repo.query!(
          "SELECT s.cpu_cores, s.memory_mb, v.default_cpu_cores, v.default_memory_mb " <>
            "FROM app_versions v JOIN pricing_sizes s ON s.id = v.recommended_size_id " <>
            "WHERE v.id = $1",
          [version_uuid]
        )

      case result.rows do
        [[cpu, memory, default_cpu, default_memory]] ->
          Decimal.eq?(cpu, default_cpu) and memory == default_memory

        [] ->
          flunk("seeded version vanished mid-test")
      end
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Removes the committed rows — the sandbox never owned them. Tolerant
  # of partial state (a failure may have removed some already). FK
  # order: versions, then the app and category, then the sizes. String
  # uuids are dumped to 16-byte binaries; ids read back from raw SQL
  # already are ones.
  defp cleanup!(version_id, from_id, target_id, opts \\ []) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      version_uuid = Ecto.UUID.dump!(version_id)

      app_id =
        scalar_or_nil(
          Repo.query!("SELECT app_id FROM app_versions WHERE id = $1", [version_uuid])
        )

      if opts[:extra_for_app] do
        Repo.query!("DELETE FROM app_versions WHERE app_id = $1", [
          Ecto.UUID.dump!(opts[:extra_for_app])
        ])
      else
        Repo.query!("DELETE FROM app_versions WHERE id = $1", [version_uuid])
      end

      category_id =
        if app_id do
          scalar_or_nil(Repo.query!("SELECT category_id FROM apps WHERE id = $1", [app_id]))
        end

      if app_id, do: Repo.query!("DELETE FROM apps WHERE id = $1", [app_id])
      if category_id, do: Repo.query!("DELETE FROM categories WHERE id = $1", [category_id])

      size_ids =
        [from_id, target_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Ecto.UUID.dump!/1)

      unless size_ids == [] do
        Repo.query!("DELETE FROM pricing_sizes WHERE id = ANY($1)", [size_ids])
      end
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  defp scalar_or_nil(result) do
    case result.rows do
      [[value]] -> value
      _gone -> nil
    end
  end

  # The fixture-slug prefixes this module's committed rows carry (and
  # nothing else in the suite commits to these tables) — on a
  # committed connection, in FK order.
  defp sweep! do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      Repo.query!(
        "DELETE FROM app_versions WHERE app_id IN (SELECT id FROM apps WHERE slug LIKE 'app-%')"
      )

      Repo.query!("DELETE FROM apps WHERE slug LIKE 'app-%'")
      Repo.query!("DELETE FROM categories WHERE slug LIKE 'tools-%'")
      Repo.query!("DELETE FROM pricing_sizes WHERE slug LIKE 'test-%'")
    after
      Sandbox.checkin(Repo, conn)
    end
  end
end
