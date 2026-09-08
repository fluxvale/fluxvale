defmodule FluxVale.Ops.AccessRules.CacheTest do
  @moduledoc false

  # async: false — the cache GenServer reads the DB from its own process,
  # which only sees this test's rows under the sandbox's shared mode. The
  # TTL is enabled per-case (config default is 0 = inert, #26); on_exit
  # restores it. A snapshot may outlive its test in memory — harmless,
  # since nothing consults the cache while the TTL is 0.
  use FluxVale.DataCase, async: false

  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.AccessRules
  alias FluxVale.Ops.AccessRules.Cache

  setup do
    Application.put_env(:flux_vale, :access_rules_cache_ttl_seconds, 300)
    on_exit(fn -> Application.put_env(:flux_vale, :access_rules_cache_ttl_seconds, 0) end)
    :ok
  end

  test "bust-on-mutation: an Ash mutation is visible on this node immediately" do
    # Create routes through BustCache — the mutating node's snapshot is
    # force-refreshed before the mutation returns (settled #26)
    AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)

    assert AccessRules.allowed?("bust-check@fluxvale.com")
    refute AccessRules.allowed?("bust-check@example.com")
  end

  test "TTL bounds staleness: reads without a bust serve the aged snapshot" do
    _rule = AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
    refute AccessRules.allowed?("stale-check@example.com")

    # A raw Repo delete bypasses the Ash hook — no bust, and the 300s TTL
    # hasn't elapsed, so the node keeps serving the old verdict (exactly
    # the cross-node behavior another replica would show)
    FluxVale.Repo.delete_all(AccessRule)
    refute AccessRules.allowed?("stale-check@example.com")

    # The forced refresh re-reads: the table is empty again — unrestricted
    :ok = Cache.refresh()
    assert AccessRules.allowed?("stale-check@example.com")
  end

  # The exact interleaving CodeRabbit asked for (#48): a read that started
  # before a mutation finishes after it — the newer state stays
  # authoritative and the stale read cannot restore revoked access
  test "a delayed read cannot restore a revoked rule (newest-read-wins)" do
    rule = AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
    refute AccessRules.allowed?("race-check@example.com")

    # Our "slow read" captured the pre-mutation read stamp…
    {_pre_snapshot, _fresh, pre_stamp} = GenServer.call(Cache, :current)

    # …then the rule is removed while that read is in flight (refresh
    # stored explicitly — the sandbox hides the transaction boundary, so
    # after_transaction hooks don't fire under test)
    :ok = Ash.destroy(rule, authorize?: false)
    :ok = Cache.refresh()

    # …and the delayed reader finishes, trying to store its stale snapshot
    :ok = GenServer.call(Cache, {:store, [rule], pre_stamp})

    # Newer state wins: the table is empty — unrestricted — and the stale
    # snapshot (which would re-deny) was discarded
    assert AccessRules.allowed?("race-check@example.com")
  end

  # The overlapping-MUTATIONS interleaving CodeRabbit asked for (#48):
  # two concurrent refreshes, the older one completing LAST — it must not
  # overwrite the newer snapshot, or a deleted rule returns for a TTL
  test "overlapping refreshes: the older one landing last cannot restore a delete" do
    keep = AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)

    gone =
      AccessRule.create!(%{email: "#{System.unique_integer()}@example.com"}, authorize?: false)

    # Refresh A starts first (stamp captured pre-delete) and is slow…
    stamp_a = System.monotonic_time() - 1
    snapshot_a = [keep, gone]

    # …refresh B (the delete's post-commit refresh) starts and lands —
    # stored explicitly: the sandbox hides the transaction boundary, so
    # after_transaction hooks don't fire under test (prod fires them —
    # the bust-on-mutation test above covers the outcome)
    :ok = Ash.destroy(gone, authorize?: false)
    :ok = Cache.refresh()

    # …then slow refresh A finally stores its pre-delete snapshot
    :ok = GenServer.call(Cache, {:store, snapshot_a, stamp_a})

    # The newest read (B's) stays authoritative: `keep` still admits its
    # domain, `gone` stays deleted — not restored for a TTL
    member = "overlap-#{System.unique_integer()}@fluxvale.com"
    assert AccessRules.allowed?(member)

    revoked = to_string(gone.email)
    refute AccessRules.allowed?(revoked)
  end
end
