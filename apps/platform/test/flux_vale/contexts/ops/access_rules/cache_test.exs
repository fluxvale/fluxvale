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
end
