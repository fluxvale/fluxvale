defmodule FluxVale.Pricing.SizeVersionCoherenceConcurrencyTest do
  @moduledoc """
  #543's fork proof, made deterministic: a size reallocation (T1)
  racing a version re-point (T2) must never leave a version whose
  compute defaults disagree with its recommended size — the fork #125
  exists to prevent. Both writers go through the real actions; the
  interleaving is gated, not slept for (#586's discipline).

  A gate connection holds the size row's FOR UPDATE lock first, so T1
  parks at exactly the statement the race lives around — pre-fix its
  UPDATE, after its unlocked probe; post-fix the probe's own lock. T2
  parks behind the same row either way (post-fix its locked read;
  pre-fix the FK's key-share on the size). Releasing the gate settles
  both writes in whatever grant order Postgres picks; the verdict is
  order-independent, so the assertions hold under every interleaving.

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

  test "a size reallocation and a version re-point cannot fork the pair" do
    %{version: version, from_id: from_id, target: target} = seeded!()
    parent = self()

    t1 =
      spawn_worker(:t1, fn ->
        announce_backend!(:t1, parent)

        Size.update(target, %{cpu_cores: Decimal.new("1"), memory_mb: 1024}, authorize?: false)
      end)

    t2 =
      spawn_worker(:t2, fn ->
        announce_backend!(:t2, parent)

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

    on_exit(fn ->
      # A failure can strand a parked worker holding the row lock —
      # kill first or the cleanup DELETEs would block on it.
      Enum.each([t1, t2], fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      cleanup!(version.id, from_id, target.id)
    end)

    # The gate: one connection holding the target size row FOR UPDATE
    # in an open transaction, parked until released.
    gate =
      spawn(fn ->
        conn = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          target_uuid = Ecto.UUID.dump!(target.id)

          Repo.query!("SELECT id FROM pricing_sizes WHERE id = $1 FOR UPDATE", [target_uuid])
          send(parent, :gate_held)

          receive do
            :release -> :ok
          end
        end)

        Sandbox.checkin(Repo, conn)
      end)

    assert_receive :gate_held, 5_000

    # T1 first: it queues on the gate before T2 starts, so the trace
    # reads as two operators racing on one size row.
    {:backend, :t1, t1_backend} = release_and_await!(t1)
    wait_until_parked!(t1_backend, "T1 (size reallocation)")

    {:backend, :t2, t2_backend} = release_and_await!(t2)
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

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1,
           "expected exactly one survivor, got: #{inspect(results)}"

    loser =
      Enum.find_value(results, fn
        {:ok, _survivor} -> nil
        {:error, error} -> Exception.message(error)
      end)

    assert loser =~ "compute is frozen" or loser =~ "must match",
           "unexpected rejection: #{loser}"
  end

  # A writer on its own real connection, gated by :go so the test can
  # sequence the two racers; reports its DB backend pid first (the
  # action runs on the connection this process checked out).
  defp spawn_worker(label, fun) do
    parent = self()

    spawn(fn ->
      conn = Sandbox.checkout(Repo, sandbox: false)

      try do
        receive do
          :go -> :ok
        end

        send(parent, {label, fun.()})
      after
        Sandbox.checkin(Repo, conn)
      end
    end)
  end

  defp announce_backend!(label, parent) do
    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(parent, {:backend, label, backend})
  end

  defp release_and_await!(worker) do
    send(worker, :go)

    receive do
      {:backend, _label, _backend} = announced -> announced
    after
      5_000 -> flunk("worker never announced its DB backend")
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

  # Seeds through the actions on a committed connection so both
  # writers see the rows: the fixture's version defaults (0.5/256)
  # match the target size's starting envelope, so T2's re-point is a
  # legal write against the state T1 is about to change.
  defp seeded! do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      version = InstanceFixtures.app_version!()

      target =
        PricingFixtures.size!(
          cpu_cores: Decimal.new("0.5"),
          memory_mb: 256,
          monthly_cents: 295
        )

      %{version: version, from_id: version.recommended_size_id, target: target}
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

      [[cpu, memory, default_cpu, default_memory]] = result.rows

      Decimal.eq?(cpu, default_cpu) and memory == default_memory
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Removes the committed rows — the sandbox never owned them. FK
  # order: the version first, then its app and category, then both
  # sizes. Raw SQL params need uuids as 16-byte binaries
  # (Ecto.UUID.dump!/1).
  defp cleanup!(version_id, from_id, target_id) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      version_uuid = Ecto.UUID.dump!(version_id)

      [[app_id]] =
        Repo.query!("SELECT app_id FROM app_versions WHERE id = $1", [version_uuid]).rows

      [[category_id]] =
        Repo.query!("SELECT category_id FROM apps WHERE id = $1", [app_id]).rows

      Repo.query!("DELETE FROM app_versions WHERE id = $1", [version_uuid])
      Repo.query!("DELETE FROM apps WHERE id = $1", [app_id])
      Repo.query!("DELETE FROM categories WHERE id = $1", [category_id])

      size_ids = [Ecto.UUID.dump!(from_id), Ecto.UUID.dump!(target_id)]
      Repo.query!("DELETE FROM pricing_sizes WHERE id = ANY($1)", [size_ids])
    after
      Sandbox.checkin(Repo, conn)
    end
  end
end
