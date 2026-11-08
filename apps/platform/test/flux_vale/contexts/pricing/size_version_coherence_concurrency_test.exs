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
  themselves are on settled rows and messages, never on a clock
  window; #586's discipline). The suite pins the fix in layers: the
  race test proves the invariant end-to-end (failing pre-fix with the
  fork), the parked-SQL tests prove each half's lock exists and has
  the right shape (FOR UPDATE on the size side, FOR SHARE on the
  version side, on update and create), and the hold-through-write
  tests prove the version side's share is still held at its own write
  — the property `before_action?` exists for, and the one a
  reverted-to-changeset-time validation loses.

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
    test "the freeze probe locks its own row before probing" do
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

      assert parked_sql!(backend, "size reallocation") =~
               ~r/SELECT.*FROM "pricing_sizes".*FOR UPDATE OF/s

      send(gate, :release)
      assert_receive {:freeze, {:ok, moved}}, 15_000
      assert Decimal.eq?(moved.cpu_cores, Decimal.new("1"))
    end

    test "a version re-point reads the size under FOR SHARE" do
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

      gate = start_gate!(target.id)

      on_exit(fn ->
        kill_if_alive(gate)
        kill_if_alive(t)
        cleanup!(version.id, from_id, target.id)
      end)

      assert_receive :gate_held, 5_000
      {:backend, :repoint, backend} = release_and_await!(t, :repoint)

      assert parked_sql!(backend, "version re-point") =~
               ~r/SELECT.*FROM "pricing_sizes".*FOR SHARE OF/s

      send(gate, :release)
      assert_receive {:repoint, {:ok, _moved}}, 15_000
    end

    # Placement, not just presence: parking at the locked read proves
    # the read locks; this proves the lock is still held AT the write —
    # only true when the validation ran inside the action's
    # transaction. A reverted `before_action?` parks at the same SELECT
    # but releases the share at statement end, and the challenge below
    # then succeeds — failing here deterministically.
    test "a re-point still holds the size row while it writes the version" do
      %{version: version, from_id: from_id, target: target} = seeded!()

      t =
        spawn_worker(:hold, fn ->
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

      # Gate the version ROW, not the size: the writer sails through
      # its validation and parks at its own UPDATE — past the read.
      gate = start_gate!(version.id, table: "app_versions")

      on_exit(fn ->
        kill_if_alive(gate)
        kill_if_alive(t)
        cleanup!(version.id, from_id, target.id)
      end)

      assert_receive :gate_held, 5_000
      {:backend, :hold, backend} = release_and_await!(t, :hold)

      wait_until_parked!(backend, "version write")

      # parked at the write (the gate is on the version row, nothing
      # else contends) with the size share still held — the placement
      # proof. `pg_stat_activity.query` is useless here: it lags one
      # statement when Postgrex pipelines, so the locks are read
      # directly.
      assert holds_size_row_share!(backend)

      send(gate, :release)
      assert_receive {:hold, {:ok, _moved}}, 15_000
    end

    test "a version create reads the size under FOR SHARE" do
      %{version: version, from_id: from_id, target: target} = seeded!()

      t =
        spawn_worker(:create, fn ->
          AppVersion.create(
            %{
              version: "2.0.#{System.unique_integer()}",
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

      gate = start_gate!(target.id)

      on_exit(fn ->
        kill_if_alive(gate)
        kill_if_alive(t)
        # The create's extra version row goes with the app's teardown —
        # delete it explicitly: it may or may not exist on failure.
        cleanup!(version.id, from_id, target.id, extra_for_app: version.app_id)
      end)

      assert_receive :gate_held, 5_000
      {:backend, :create, backend} = release_and_await!(t, :create)

      assert parked_sql!(backend, "version create") =~
               ~r/SELECT.*FROM "pricing_sizes".*FOR SHARE OF/s

      send(gate, :release)
      assert_receive {:create, {:ok, _created}}, 15_000
    end

    # Same placement proof as the re-point's, for the create path: the
    # writer parks at its INSERT (gated through the app row's FK) with
    # the size share still held.
    test "a create still holds the size row while it writes the version" do
      %{version: version, from_id: from_id, target: target} = seeded!()

      t =
        spawn_worker(:hold_create, fn ->
          AppVersion.create(
            %{
              version: "2.0.#{System.unique_integer()}",
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

      # Gate the APP row: the create's FK check parks the INSERT while
      # the validation's size share is already held.
      gate = start_gate!(version.app_id, table: "apps")

      on_exit(fn ->
        kill_if_alive(gate)
        kill_if_alive(t)
        cleanup!(version.id, from_id, target.id, extra_for_app: version.app_id)
      end)

      assert_receive :gate_held, 5_000
      {:backend, :hold_create, backend} = release_and_await!(t, :hold_create)

      wait_until_parked!(backend, "version insert")
      assert holds_size_row_share!(backend)

      send(gate, :release)
      assert_receive {:hold_create, {:ok, _created}}, 15_000
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
    _sql = parked_sql!(backend, label, polls_left)
    :ok
  end

  # Same convergence as wait_until_parked!/2, returning the parked
  # statement's SQL — the half-pinning tests assert on it because the
  # parked statement IS the fix: pre-fix, the same workers park on the
  # raw UPDATE/INSERT instead.
  defp parked_sql!(backend, label, polls_left \\ @park_budget_polls)

  defp parked_sql!(backend, label, polls_left) do
    result =
      Repo.query!("SELECT wait_event_type, query FROM pg_stat_activity WHERE pid = $1", [backend])

    case result.rows do
      [["Lock", sql]] ->
        sql

      _not_yet when polls_left > 1 ->
        Process.sleep(@poll_interval_ms)
        parked_sql!(backend, label, polls_left - 1)

      _never ->
        flunk("#{label} never parked on the size row lock")
    end
  end

  # A parked worker's abandoned checkout is reclaimed by DBConnection
  # on owner death, rolling its transaction back — safe to kill.
  defp kill_if_alive(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  # True when the backend's open transaction holds a granted
  # RowShareLock on pricing_sizes — the in-transaction footprint of
  # the validation's locked read; relation locks persist to
  # transaction end. A validation that ran at changeset time released
  # it at statement end, so held *while parked at the write* is the
  # placement proof: the lock rides to commit. (RowShareLock is
  # relation-level: FOR SHARE and FOR UPDATE row locks both take it —
  # the mode is pinned by the shape tests instead.)
  defp holds_size_row_share!(backend) do
    result =
      Repo.query!(
        "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
          "WHERE l.pid = $1 AND l.granted AND l.mode = 'RowShareLock' " <>
          "AND c.relname = 'pricing_sizes'",
        [backend]
      )

    [[count]] = result.rows
    count > 0
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
