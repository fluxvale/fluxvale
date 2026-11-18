defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.TokenCacheTest do
  @moduledoc """
  The OAuth access-token cache (#836 lane B): one exchange per client
  per hour, the 300s skew refresh, invalidate-then-fresh-exchange,
  failure propagation, and the no-leakage discipline (the table is
  app-global, so every test clears it — pinned here, not just done).
  """

  # async: false — the table is a named, app-tree-owned singleton; ExUnit
  # runs sync modules alone, which is what makes clear-in-setup sound.
  use ExUnit.Case, async: false
  use Mimic

  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.TokenCache

  @client_id "ts-client-id-1"
  @client_secret "ts-client-secret-1"

  # The exchange stub, counting per test process — the call-count pins
  # ("no second exchange", "re-exchanges") are the point of this suite.
  defp stub_exchange do
    stub(ApiClient, :oauth_exchange, fn _client_id, _client_secret ->
      count = Process.get(:exchange_count, 0) + 1
      Process.put(:exchange_count, count)

      {:ok, %{access_token: "tskey-token-#{count}", expires_in: 3600}}
    end)
  end

  setup do
    TokenCache.clear()
    stub_exchange()
    :ok
  end

  defp exchange_count, do: Process.get(:exchange_count, 0)

  describe "fetch/3" do
    test "exchanges once and serves the cached token with no second exchange" do
      now = DateTime.utc_now()

      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)
      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)
      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)

      assert exchange_count() == 1
    end

    test "serves from the cache until the skew window, then exchanges fresh" do
      now = DateTime.utc_now()

      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)

      # expires_at = now + 3600; fresh while now' < expires_at − 300.
      # 3299s in: still inside the window — no second exchange.
      inside = DateTime.add(now, 3600 - 300 - 1, :second)
      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, inside)
      assert exchange_count() == 1

      # The boundary itself (now' == expires_at − 300) is already stale:
      # the skew window buys the refresh, it does not risk the expiry.
      boundary = DateTime.add(now, 3600 - 300, :second)
      assert {:ok, "tskey-token-2"} = TokenCache.fetch(@client_id, @client_secret, boundary)
      assert exchange_count() == 2
    end

    test "invalidate-then-fetch exchanges fresh" do
      now = DateTime.utc_now()

      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)

      :ok = TokenCache.invalidate(@client_id)

      assert {:ok, "tskey-token-2"} = TokenCache.fetch(@client_id, @client_secret, now)
      assert exchange_count() == 2
    end

    test "an exchange failure propagates and caches nothing" do
      stub(ApiClient, :oauth_exchange, fn _client_id, _client_secret ->
        {:error, :unauthorized}
      end)

      assert {:error, :unauthorized} = TokenCache.fetch(@client_id, @client_secret)
      assert :ets.lookup(table(), @client_id) == []

      # A later good exchange starts clean — the failure never stuck.
      stub_exchange()
      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret)
      assert exchange_count() == 1
    end

    test "keys by client_id — two clients never share an entry" do
      now = DateTime.utc_now()

      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)
      assert {:ok, "tskey-token-2"} = TokenCache.fetch("ts-client-id-2", @client_secret, now)
      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)

      assert exchange_count() == 2
    end

    test "a stale entry is erased on expiry (custody: erased, not served)" do
      now = DateTime.utc_now()

      assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)
      assert [_entry] = :ets.lookup(table(), @client_id)

      stale = DateTime.add(now, 3600, :second)
      assert {:ok, "tskey-token-2"} = TokenCache.fetch(@client_id, @client_secret, stale)
      assert [%{token: "tskey-token-2"}] = entries()
    end
  end

  test "invalidate on an unknown client is a no-op :ok" do
    assert :ok = TokenCache.invalidate("never-fetched")
  end

  # The leakage pin: the app-global table is empty after clear/0 — the
  # discipline every pair-path test's setup relies on.
  test "clear/0 empties the table — tokens do not leak between tests" do
    now = DateTime.utc_now()
    assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)
    assert entries() != []

    assert :ok = TokenCache.clear()
    assert entries() == []
  end

  # A ROTATED secret under the same client id must not ride the old
  # bearer (#863 review): the fingerprint binds entries to the pair
  # that minted them, and the raw secret never touches the table.
  test "a rotated secret under the same client id is a miss — a fresh exchange mints" do
    now = DateTime.utc_now()
    assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)
    assert exchange_count() == 1

    assert {:ok, "tskey-token-2"} =
             TokenCache.fetch(@client_id, "ts-client-secret-ROTATED", now)

    assert exchange_count() == 2
    # The raw secret is nowhere in the table — only its digest rides.
    refute inspect(:ets.tab2list(table())) =~ @client_secret
    refute inspect(:ets.tab2list(table())) =~ "ts-client-secret-ROTATED"
  end

  # The retry path's fetch (#863 review): the cache READ is bypassed —
  # a stale entry published by an in-flight pre-invalidation exchange
  # can never answer the retry — while the fresh result still caches.
  test "fetch_fresh bypasses the cache read but caches its result" do
    now = DateTime.utc_now()
    assert {:ok, "tskey-token-1"} = TokenCache.fetch(@client_id, @client_secret, now)

    assert {:ok, "tskey-token-2"} = TokenCache.fetch_fresh(@client_id, @client_secret)
    assert exchange_count() == 2

    # And the fresh entry now serves plain fetches.
    assert {:ok, "tskey-token-2"} = TokenCache.fetch(@client_id, @client_secret, now)
    assert exchange_count() == 2
  end

  defp table, do: TokenCache.Cache

  # A :protected table reads from any process — the assertions may peek.
  defp entries do
    for {_client_id, entry} <- :ets.tab2list(table()), do: entry
  end
end
