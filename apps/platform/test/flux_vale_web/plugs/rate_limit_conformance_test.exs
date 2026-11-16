defmodule FluxValeWeb.Plugs.RateLimitConformanceTest do
  @moduledoc false

  # #510: the same request sequence through the frozen pre-lane
  # implementations and the live ones, before any consolidation. This
  # suite is characterization: it pins what the two fixed-window stores
  # do today, including the two differences the lane must decide (the
  # OAuth existing-claim bypass and Google's inline over-cap sweep).
  # async: false — the config cases mutate Application env (the
  # ApiRateLimit config-test posture) and the tables are VM-global.
  #
  # IP convention: conformance addresses live in 198.18/15; the plug
  # suites never use that range, so leftover counter rows cannot collide.
  # The OAuth sweep stamp is cleared around every case.
  # Day-long windows carry the plug suites' accepted UTC-midnight
  # millisecond straddle.

  use ExUnit.Case, async: false

  alias FluxVale.TestSupport.LegacyGoogleRateLimit
  alias FluxVale.TestSupport.LegacyOAuthRateLimit
  alias FluxVale.TestSupport.RateLimitConformance
  alias FluxValeWeb.Plugs.GoogleRateLimit
  alias FluxValeWeb.Plugs.OAuthRateLimit

  @google_modules [GoogleRateLimit, LegacyGoogleRateLimit]
  @oauth_modules [OAuthRateLimit, LegacyOAuthRateLimit]
  @all_modules @google_modules ++ @oauth_modules

  @shared_verdicts [:ok, :ok, :refused, :refused, :ok, :refused, :refused]
  @window_seconds 86_400

  setup do
    clear_oauth_claim()
    start_supervised!({LegacyGoogleRateLimit, []})
    start_supervised!({LegacyOAuthRateLimit, []})
    # The owners' initial :sweep must run before a test installs a
    # malformed config, or the queued message would crash them. The live
    # owners are app-supervised; sync them too.
    :sys.get_state(LegacyGoogleRateLimit)
    :sys.get_state(LegacyOAuthRateLimit)
    :sys.get_state(GoogleRateLimit)
    :sys.get_state(OAuthRateLimit)
    on_exit(&clear_oauth_claim/0)
    :ok
  end

  describe "the frozen oracles" do
    test "the Google oracle matches the live module on the shared sequence" do
      with_config(google_opts(), oauth_opts(), fn ->
        window = window(@window_seconds)
        {steps, ip_c, ip_stale} = shared_sequence(window)
        legacy = RateLimitConformance.legacy_google()
        current = RateLimitConformance.current_google()

        legacy_results = RateLimitConformance.run(legacy, steps)
        current_results = RateLimitConformance.run(current, steps)

        assert RateLimitConformance.verdicts(legacy_results) ==
                 RateLimitConformance.verdicts(current_results)

        assert RateLimitConformance.verdicts(current_results) == @shared_verdicts
        assert row_count(current, :register, ip_c, window) == 101
        assert row_count(legacy, :register, ip_c, window) == 101
        assert stale_row(current, ip_stale) == []
        assert stale_row(legacy, ip_stale) == []
      end)
    end

    test "the OAuth oracle matches the live module on the shared sequence" do
      with_config(google_opts(), oauth_opts(), fn ->
        window = window(@window_seconds)
        {steps, ip_c, ip_stale} = shared_sequence(window)
        legacy = RateLimitConformance.legacy_oauth()
        current = RateLimitConformance.current_oauth()

        legacy_results = RateLimitConformance.run(legacy, steps)
        current_results = RateLimitConformance.run(current, steps)

        assert RateLimitConformance.verdicts(legacy_results) ==
                 RateLimitConformance.verdicts(current_results)

        assert RateLimitConformance.verdicts(current_results) == @shared_verdicts
        assert row_count(current, :register, ip_c, window) == 101
        assert row_count(legacy, :register, ip_c, window) == 101
        assert stale_row(current, ip_stale) == []
        assert stale_row(legacy, ip_stale) == []
      end)
    end
  end

  describe "the shared fixed-window semantics" do
    test "Google and OAuth agree on the same request sequence" do
      with_config(google_opts(), oauth_opts(), fn ->
        window = window(@window_seconds)
        {steps, ip_c, ip_stale} = shared_sequence(window)

        google = RateLimitConformance.current_google()
        oauth = RateLimitConformance.current_oauth()

        google_results = RateLimitConformance.run(google, steps)
        oauth_results = RateLimitConformance.run(oauth, steps)

        assert RateLimitConformance.verdicts(google_results) ==
                 RateLimitConformance.verdicts(oauth_results)

        assert row_count(google, :register, ip_c, window) == 101
        assert row_count(oauth, :register, ip_c, window) == 101
        assert stale_row(google, ip_stale) == []
        assert stale_row(oauth, ip_stale) == []
      end)
    end

    test "the OAuth buckets are isolated" do
      buckets =
        Map.new([:register, :authorize, :token, :revoke], fn bucket ->
          {bucket, [window_seconds: @window_seconds, max_requests: 1]}
        end)

      with_config(google_opts(), [max_rows: 100_000, buckets: buckets], fn ->
        for {_name, adapter} <- RateLimitConformance.oauth_adapters() do
          ip = RateLimitConformance.unique_ip()
          conn = conn_for(ip)

          assert :ok = adapter.allow.(conn, :register)
          assert :ok = adapter.allow.(conn, :token)
          assert :ok = adapter.allow.(conn, :authorize)
          assert :ok = adapter.allow.(conn, :revoke)
          assert {:error, _retry} = adapter.allow.(conn, :register)
          assert {:error, _retry} = adapter.allow.(conn, :token)
          assert {:error, _retry} = adapter.allow.(conn, :authorize)
          assert {:error, _retry} = adapter.allow.(conn, :revoke)
        end
      end)
    end

    test "the sweep keeps live rows and drops lapsed ones" do
      with_config(google_opts(), oauth_opts(), fn ->
        window = window(@window_seconds)

        adapters =
          RateLimitConformance.google_adapters() ++ RateLimitConformance.oauth_adapters()

        for {_name, adapter} <- adapters do
          ip = RateLimitConformance.unique_ip()

          keys =
            Map.new(
              [0, -1, -2, -3],
              &{&1, adapter.key.(:register, ip, window + &1 * @window_seconds)}
            )

          Enum.each(keys, fn {_offset, key} -> :ets.insert(adapter.table, {key, 1}) end)
          assert :ok = adapter.sweep.()

          current_key = Map.fetch!(keys, 0)
          previous_key = Map.fetch!(keys, -1)
          two_windows_key = Map.fetch!(keys, -2)
          lapsed_key = Map.fetch!(keys, -3)

          assert :ets.member(adapter.table, current_key)
          assert :ets.member(adapter.table, previous_key)
          refute :ets.member(adapter.table, lapsed_key)

          # -2: both Google copies' floor cutoff keeps it (equal is not
          # <); the old OAuth now-relative cutoff may drop it. S3's floor
          # formula makes the unified result deterministic and asserts it
          # there.
          if adapter.name in [:legacy_google, :current_google] do
            assert :ets.member(adapter.table, two_windows_key)
          end
        end
      end)
    end

    test "window_start/2 floors to the boundary on every implementation" do
      for module <- @all_modules do
        assert module.window_start(179, 60) == 120
        assert module.window_start(120, 60) == 120
        assert module.window_start(119, 60) == 60
      end
    end

    test "malformed Google config raises at the boundary" do
      with_config(google_opts(window_seconds: 0), oauth_opts(), fn ->
        conn = conn_for(RateLimitConformance.unique_ip())

        for module <- @google_modules do
          assert_raise ArgumentError, ~r/window_seconds/, fn ->
            module.allow?(conn)
          end
        end
      end)
    end

    test "malformed OAuth config raises at the boundary" do
      bad = [max_rows: 100_000, buckets: %{register: [window_seconds: 0, max_requests: 1]}]

      with_config(google_opts(), bad, fn ->
        conn = conn_for(RateLimitConformance.unique_ip())

        for module <- @oauth_modules do
          assert_raise ArgumentError, ~r/window_seconds/, fn ->
            module.allow?(conn, :register)
          end
        end
      end)
    end
  end

  describe "the differences this lane must decide" do
    test "pre-fix: an existing claim lets a saturated key through (legacy and live)" do
      cap_opts = [
        max_rows: 1,
        buckets: %{
          register: [window_seconds: @window_seconds, max_requests: 2],
          authorize: [window_seconds: @window_seconds, max_requests: 2],
          token: [window_seconds: @window_seconds, max_requests: 2],
          revoke: [window_seconds: @window_seconds, max_requests: 2]
        }
      ]

      with_config(google_opts(), cap_opts, fn ->
        window = window(@window_seconds)

        # S1 pins the pre-fix behavior of BOTH copies; S2 flips the live
        # half to {:error, _} + counter+1 + this fresh stamp UNCHANGED
        # (the guard only replaces a stale stamp — that is S2's second
        # case, staged as 0).
        for adapter <- [
              RateLimitConformance.legacy_oauth(),
              RateLimitConformance.current_oauth()
            ] do
          now = System.system_time(:second)
          other = RateLimitConformance.unique_ip()
          target = RateLimitConformance.unique_ip()

          other_key = adapter.key.(:register, other, window)
          target_key = adapter.key.(:register, target, window)
          conn = conn_for(target)

          :ets.insert(adapter.table, {other_key, 1})
          :ets.insert(adapter.table, {target_key, 2})
          # A FRESH claim: the bad select_replace body raises whether or
          # not the stamp is stale; any existing row is enough.
          :ets.insert(adapter.table, {{:sweep, :last}, now})

          assert :ok = adapter.allow.(conn, :register)

          assert :ets.lookup(adapter.table, target_key) == [{target_key, 2}]
          assert :ets.lookup(adapter.table, {:sweep, :last}) == [{{:sweep, :last}, now}]
        end
      end)
    end

    test "Google sweeps inline on each over-cap request; OAuth's fresh claim skips" do
      google_cap = google_opts(max_rows: 1, max_requests: 10)

      oauth_cap = [
        max_rows: 1,
        buckets: %{
          register: [window_seconds: @window_seconds, max_requests: 10],
          authorize: [window_seconds: @window_seconds, max_requests: 10],
          token: [window_seconds: @window_seconds, max_requests: 10],
          revoke: [window_seconds: @window_seconds, max_requests: 10]
        }
      ]

      with_config(google_cap, oauth_cap, fn ->
        window = window(@window_seconds)

        adapters =
          RateLimitConformance.google_adapters() ++ RateLimitConformance.oauth_adapters()

        for {_name, adapter} <- adapters do
          first = RateLimitConformance.unique_ip()
          second = RateLimitConformance.unique_ip()
          third = RateLimitConformance.unique_ip()
          stale_one = RateLimitConformance.unique_ip()
          stale_two = RateLimitConformance.unique_ip()

          for ip <- [RateLimitConformance.unique_ip(), RateLimitConformance.unique_ip()] do
            key = adapter.key.(:register, ip, window)
            :ets.insert(adapter.table, {key, 1})
          end

          # First over-cap request: Google sweeps inline (no claim row);
          # OAuth inserts its claim and sweeps.
          first_conn = conn_for(first)
          first_result = adapter.allow.(first_conn, :register)
          assert RateLimitConformance.decision(first_result) == :ok

          stale_one_key = adapter.key.(:register, stale_one, window - 3 * @window_seconds)
          :ets.insert(adapter.table, {stale_one_key, 99})

          # Second over-cap request: Google reaps stale_one; OAuth's
          # fresh claim blocks the scan (and the broken select_replace
          # turns the request into an uncounted allow).
          second_conn = conn_for(second)
          second_result = adapter.allow.(second_conn, :register)
          assert RateLimitConformance.decision(second_result) == :ok

          stale_two_key = adapter.key.(:register, stale_two, window - 3 * @window_seconds)
          :ets.insert(adapter.table, {stale_two_key, 99})

          # Third over-cap request: Google reaps again (the inline sweep
          # is per request); OAuth still holds its claim.
          third_conn = conn_for(third)
          third_result = adapter.allow.(third_conn, :register)
          assert RateLimitConformance.decision(third_result) == :ok

          second_key = adapter.key.(:register, second, window)
          third_key = adapter.key.(:register, third, window)

          if adapter.name in [:legacy_google, :current_google] do
            refute :ets.member(adapter.table, stale_one_key)
            refute :ets.member(adapter.table, stale_two_key)
            refute :ets.member(adapter.table, {:sweep, :last})
            assert :ets.member(adapter.table, second_key)
            assert :ets.member(adapter.table, third_key)
          else
            assert :ets.member(adapter.table, stale_one_key)
            assert :ets.member(adapter.table, stale_two_key)
            assert :ets.member(adapter.table, {:sweep, :last})
            refute :ets.member(adapter.table, second_key)
            refute :ets.member(adapter.table, third_key)
          end
        end
      end)
    end
  end

  # The shared request story: two allowed, two refused (the refused
  # requests still count), a distinct IP, a staged saturated IP, a lapsed
  # row swept, then the saturated current row still refused.
  defp shared_sequence(window) do
    ip_a = RateLimitConformance.unique_ip()
    ip_b = RateLimitConformance.unique_ip()
    ip_c = RateLimitConformance.unique_ip()
    ip_stale = RateLimitConformance.unique_ip()

    conn_a = conn_for(ip_a)
    conn_b = conn_for(ip_b)
    conn_c = conn_for(ip_c)

    steps = [
      RateLimitConformance.allow(conn_a, :register),
      RateLimitConformance.allow(conn_a, :register),
      RateLimitConformance.allow(conn_a, :register),
      RateLimitConformance.allow(conn_a, :register),
      RateLimitConformance.allow(conn_b, :register),
      RateLimitConformance.stage(:register, ip_c, window, 99),
      RateLimitConformance.allow(conn_c, :register),
      RateLimitConformance.stage(:register, ip_stale, 0, 99),
      RateLimitConformance.sweep(),
      RateLimitConformance.allow(conn_c, :register)
    ]

    {steps, ip_c, ip_stale}
  end

  defp stale_row(adapter, ip) do
    key = adapter.key.(:register, ip, 0)
    :ets.lookup(adapter.table, key)
  end

  defp row_count(adapter, bucket, ip, window) do
    key = adapter.key.(bucket, ip, window)
    [{^key, count}] = :ets.lookup(adapter.table, key)
    count
  end

  defp conn_for(ip) do
    remote_ip = RateLimitConformance.ip_tuple(ip)
    RateLimitConformance.conn([], remote_ip)
  end

  # The cap scenarios leave the shared OAuth table's sweep stamp fresh;
  # the plug suite's cap test assumes it starts absent. Restore that
  # posture around every conformance case (the suite is async: false).
  defp clear_oauth_claim do
    :ets.delete(OAuthRateLimit.Windows, {:sweep, :last})
    :ok
  end

  defp with_config(google_opts, oauth_opts, fun) do
    originals = Enum.map(@all_modules, &{&1, Application.get_env(:flux_vale, &1)})
    Enum.each(@google_modules, &Application.put_env(:flux_vale, &1, google_opts))
    Enum.each(@oauth_modules, &Application.put_env(:flux_vale, &1, oauth_opts))
    on_exit(fn -> Enum.each(originals, &restore/1) end)
    fun.()
  end

  defp restore({module, nil}), do: Application.delete_env(:flux_vale, module)
  defp restore({module, value}), do: Application.put_env(:flux_vale, module, value)

  defp google_opts(overrides \\ []) do
    Keyword.merge(
      [window_seconds: @window_seconds, max_requests: 2, max_rows: 100_000],
      overrides
    )
  end

  defp oauth_opts(overrides \\ []) do
    Keyword.merge(
      [
        max_rows: 100_000,
        buckets: %{
          register: [window_seconds: @window_seconds, max_requests: 2],
          authorize: [window_seconds: @window_seconds, max_requests: 2],
          token: [window_seconds: @window_seconds, max_requests: 2],
          revoke: [window_seconds: @window_seconds, max_requests: 2]
        }
      ],
      overrides
    )
  end

  defp window(seconds), do: div(System.system_time(:second), seconds) * seconds
end
