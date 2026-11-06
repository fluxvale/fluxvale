defmodule FluxVale.Infrastructure.Operations.StorageExpansionTest do
  @moduledoc """
  #493's capability seam: the live allowVolumeExpansion probe, cached
  per cluster (unique cluster rows per test, so no cache clearing), the
  probe running in the caller's process (Mimic stubs are
  process-local).
  """

  # async: false — the owner-kill test suspends the shared app
  # supervisor for its restart-window assertion; the sync wave keeps
  # concurrent resize/probe tests out of that window.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Infrastructure.Operations.StorageExpansion
  alias FluxVale.TestSupport.InstanceFixtures

  # The seam's arg is an instance-shaped map (cluster_id key) — what
  # the resize guard passes. Kubeconfig resolution goes through the
  # cluster row (the stop/start tests' stub shape).
  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  test "a default class with allowVolumeExpansion true is capable" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    assert {:ok, true} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end

  test "local-path today: a default class without expansion answers false" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

    assert {:ok, false} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end

  test "no default class answers false" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

    assert {:ok, false} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end

  test "a probe error returns the error honestly (and is not cached)" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()

    expect(StorageClass, :default_allows_expansion?, fn _kc ->
      {:error, Error.connection_error("api server on fire")}
    end)

    assert {:error, _reason} = StorageExpansion.capable?(%{cluster_id: cluster.id})

    # Not cached: the retry re-probes (and may now succeed).
    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    assert {:ok, true} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end

  test "a second call within the TTL hits the cache — the probe client runs exactly once" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()

    expect(StorageClass, :default_allows_expansion?, 1, fn _kc -> {:ok, true} end)

    assert {:ok, true} = StorageExpansion.capable?(%{cluster_id: cluster.id})
    assert {:ok, true} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end

  test "different clusters probe independently" do
    stub_kubeconfig()
    expandable = InstanceFixtures.local_cluster!()
    not_expandable = InstanceFixtures.local_cluster!()

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

    assert {:ok, true} = StorageExpansion.capable?(%{cluster_id: expandable.id})
    assert {:ok, false} = StorageExpansion.capable?(%{cluster_id: not_expandable.id})
  end

  # The supervisor restart window (owner crashed): a raw ETS lookup
  # would raise ArgumentError out of the seam — the seam must answer an
  # error tuple instead, and self-heal when the owner is back.
  test "a TTL-expired entry re-probes (the fresh probe wins)" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()

    # Seed the public cache table with a just-expired entry (the table
    # shape: {cluster_id, value, expires_at_monotonic_ms}).
    expired_at = System.monotonic_time(:millisecond) - 1

    :ets.insert(StorageExpansion.Cache, {cluster.id, false, expired_at})

    # The stale entry misses: the probe client runs exactly once for
    # the next ask, and the fresh answer lands.
    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    assert {:ok, true} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end

  # A table gone without its owner (data-side delete — not a shape the
  # seam produces) answers the same clean tuple via the whereis guard;
  # pinned so a missing table can never surface as a raise.
  test "a table lost under a living owner is the same clean tuple" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()

    :sys.suspend(FluxVale.Supervisor)

    # No live probe under the dead table — the error tuple is the
    # assertion, the stub keeps any later probe deterministic.
    stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

    :ets.delete(StorageExpansion.Cache)

    assert {:error, :cache_unavailable} = StorageExpansion.capable?(%{cluster_id: cluster.id})

    # Restore: kill the owner so the supervisor's restart re-creates
    # the table; the mailbox-ordered count_children call proves the
    # restart landed before the test returns. No sleeps.
    owner = Process.whereis(StorageExpansion)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

    :sys.resume(FluxVale.Supervisor)
    Supervisor.count_children(FluxVale.Supervisor)

    assert {:ok, false} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end

  test "a dead cache owner is a clean error tuple, not a raise; the seam self-heals" do
    stub_kubeconfig()
    cluster = InstanceFixtures.local_cluster!()
    owner = Process.whereis(StorageExpansion)
    ref = Process.monitor(owner)

    # Suspend the app supervisor so the restart can't race the
    # assertion; the killed owner's EXIT queues in its mailbox.
    :sys.suspend(FluxVale.Supervisor)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

    assert {:error, :cache_unavailable} = StorageExpansion.capable?(%{cluster_id: cluster.id})

    # Resume, then synchronize on the restart through the supervisor's
    # own mailbox ordering: the queued EXIT predates this call, so by
    # the time count_children/1 answers, the owner is restarted and its
    # init has re-created the table. No sleeps.
    :sys.resume(FluxVale.Supervisor)
    Supervisor.count_children(FluxVale.Supervisor)

    # Self-healed: the fresh owner's table serves a fresh probe.
    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    assert {:ok, true} = StorageExpansion.capable?(%{cluster_id: cluster.id})
  end
end
