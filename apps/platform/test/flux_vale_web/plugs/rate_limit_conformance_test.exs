defmodule FluxValeWeb.Plugs.RateLimitConformanceTest do
  @moduledoc false

  # #510: one request sequence through both live fixed-window
  # implementations. This suite pins the shared semantics (the surfaces
  # agree on the same story), the engine's own behavior (fail-open,
  # owner lifecycle), and the hard row cap. The frozen pre-lane oracles
  # that proved the S1-S5 refactor behavior-preserving were deleted at
  # lane close; the paired old-vs-new evidence lives in those PRs.
  # async: false — the config cases mutate Application env (the
  # ApiRateLimit config-test posture) and the tables are VM-global.
  #
  # IP convention: conformance addresses live in 198.18/15; the plug
  # suites never use that range, so leftover counter rows cannot collide.
  # The sweep stamps are cleared around every case.
  # Day-long windows carry the plug suites' accepted UTC-midnight
  # millisecond straddle.

  use ExUnit.Case, async: false

  alias FluxVale.TestSupport.FixedWindowTestSource
  alias FluxVale.TestSupport.RateLimitConformance
  alias FluxValeWeb.Plugs.FixedWindow
  alias FluxValeWeb.Plugs.GoogleRateLimit
  alias FluxValeWeb.Plugs.OAuthRateLimit

  @google_modules [GoogleRateLimit]
  @oauth_modules [OAuthRateLimit]
  @all_modules @google_modules ++ @oauth_modules

  @shared_verdicts [:ok, :ok, :refused, :refused, :ok, :refused, :refused]
  @window_seconds 86_400

  setup do
    clear_claim_stamps()
    # The live owners' initial :sweep must run before a test installs a
    # malformed config, or the queued message would crash them.
    :sys.get_state(GoogleRateLimit)
    :sys.get_state(OAuthRateLimit)
    on_exit(&clear_claim_stamps/0)
    :ok
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

        # The absolute pin: agreeing with each other is not enough —
        # both surfaces must still tell this exact story.
        assert RateLimitConformance.verdicts(google_results) == @shared_verdicts

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
        adapter = RateLimitConformance.current_oauth()
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
      end)
    end

    test "the sweep keeps live rows and drops lapsed ones" do
      with_config(google_opts(), oauth_opts(), fn ->
        window = window(@window_seconds)

        adapters = [RateLimitConformance.current_google(), RateLimitConformance.current_oauth()]

        for adapter <- adapters do
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

          # -2: the engine's floor cutoff (window_start - 2w) keeps the
          # boundary row — equal is not <.
          assert :ets.member(adapter.table, two_windows_key)
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

  describe "the engine" do
    test "a stopped owner fails open, and a restart serves a fresh table" do
      source = FixedWindowTestSource

      start_supervised!({FixedWindow, source: source, id: :engine_probe})
      :sys.get_state(source)

      first = RateLimitConformance.unique_ip()
      assert :ok = FixedWindow.allow?(source, :probe, first)

      # The table dies with the owner; the next request must not raise —
      # a throttle must not 500 the sign-in door. The request is allowed
      # and uncounted; the next owner counts again.
      :ok = stop_supervised!(:engine_probe)
      second = RateLimitConformance.unique_ip()
      assert :ok = FixedWindow.allow?(source, :probe, second)
      assert :ets.whereis(source.table()) == :undefined

      start_supervised!({FixedWindow, source: source, id: :engine_probe})
      :sys.get_state(source)

      third = RateLimitConformance.unique_ip()
      assert :ok = FixedWindow.allow?(source, :probe, third)

      third_key = {:probe, third, window(@window_seconds)}
      assert :ets.lookup(source.table(), third_key) == [{third_key, 1}]
    end
  end

  describe "the hard bound" do
    setup do
      original = Application.get_env(:flux_vale, FixedWindowTestSource)
      Application.put_env(:flux_vale, FixedWindowTestSource, max_rows: 3)
      on_exit(fn -> restore_env(FixedWindowTestSource, original) end)
      :ok
    end

    test "past the cap a missing key is admitted uncounted and inserts nothing" do
      source = FixedWindowTestSource
      window = window(@window_seconds)

      start_supervised!({FixedWindow, source: source, id: :engine_probe})
      :sys.get_state(source)

      # Four live rows past the cap of 3, with a fresh claim so the cap
      # path runs without sweeping. (Static TEST-NET-3 addresses: the
      # flood below draws from 198.18/15 and must not collide.)
      for i <- 1..4 do
        :ets.insert(source.table(), {{:probe, "203.0.113.#{i}", window}, 1})
      end

      now = System.system_time(:second)
      :ets.insert(source.table(), {{:sweep, :last}, now})
      saturated_size = :ets.info(source.table(), :size)

      # A flood of new keys: every request is allowed, none counts, and
      # the table does not grow by a single row.
      Enum.each(1..100, fn _i ->
        ip = RateLimitConformance.unique_ip()
        assert :ok = FixedWindow.allow?(source, :probe, ip)
        refute :ets.member(source.table(), {:probe, ip, window})
      end)

      assert :ets.info(source.table(), :size) == saturated_size

      # An existing key still counts and refuses — no reset, no bypass.
      target = "203.0.113.7"
      :ets.insert(source.table(), {{:probe, target, window}, 2})

      target_result = FixedWindow.allow?(source, :probe, target)
      assert {:error, _retry} = target_result

      assert :ets.lookup(source.table(), {:probe, target, window}) == [
               {{:probe, target, window}, 3}
             ]
    end

    test "the stale-claim sweep reclaims headroom and inserts resume" do
      source = FixedWindowTestSource
      window = window(@window_seconds)

      start_supervised!({FixedWindow, source: source, id: :engine_probe})
      :sys.get_state(source)
      :ets.delete(source.table(), {:sweep, :last})

      # Saturate with four LAPSED rows; no claim exists, so the first
      # request claims, sweeps them all, and lands its own row.
      for i <- 1..4 do
        :ets.insert(source.table(), {{:probe, "203.0.113.1#{i}", 0}, 99})
      end

      first = RateLimitConformance.unique_ip()
      assert :ok = FixedWindow.allow?(source, :probe, first)
      first_key = {:probe, first, window}
      assert :ets.lookup(source.table(), first_key) == [{first_key, 1}]
      assert :ets.info(source.table(), :size) == 2
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

  # The cap scenarios leave a fresh sweep stamp in BOTH shared tables
  # (since S4 the Google table carries one too). The plug suites' cap
  # tests own their claim state and delete-first anyway — clearing both
  # stamps here keeps that invariant local instead of living in another
  # file. Runs around every conformance case (the suite is async:
  # false).
  defp clear_claim_stamps do
    :ets.delete(OAuthRateLimit.Windows, {:sweep, :last})
    :ets.delete(GoogleRateLimit.Windows, {:sweep, :last})
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

  defp restore_env(module, nil), do: restore({module, nil})
  defp restore_env(module, value), do: restore({module, value})

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
