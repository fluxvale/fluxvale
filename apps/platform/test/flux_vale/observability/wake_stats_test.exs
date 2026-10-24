defmodule FluxVale.Observability.WakeStatsTest do
  @moduledoc """
  The catalog badge's derivation (#232): median total per app off the
  live scrape, PromQL-interpolated; the min-samples honesty guard; the
  TTL cache; the down-tree {} posture.

  async: false — the scrape tests start the module-named PromEx tree
  (VM-global), and WakeStats itself is the app tree's named server.
  """

  use FluxVale.DataCase, async: false

  alias FluxVale.Observability.WakeStats

  # test.exs pins the TTL to 0 — every read recomputes; the cache test
  # raises it per-case and restores on exit (capture-and-restore).
  defp with_ttl(ttl) do
    Application.put_env(:flux_vale, :wake_stats_ttl_seconds, ttl)

    on_exit(fn ->
      Application.put_env(:flux_vale, :wake_stats_ttl_seconds, 0)
    end)
  end

  defp emit_total(app, duration) do
    :telemetry.execute([:flux_vale, :wake, :total], %{duration: duration}, %{app: app})
  end

  test "{} while the metrics tree is down" do
    assert WakeStats.median_total_by_app() == %{}
  end

  test "an app with enough samples gets the interpolated median" do
    start_supervised!(FluxVale.PromEx)

    # Five identical 6s wakes: everything lands in le=8, so
    # histogram_quantile interpolates uniformly across (5, 8] —
    # target rank 2.5 of 5 lands at 5 + (8-5) * 2.5/5 = 6.5.
    for _wake <- 1..5, do: emit_total("kavita", 6.0)

    medians = WakeStats.median_total_by_app()

    assert_in_delta Map.fetch!(medians, "kavita"), 6.5, 0.01
  end

  test "below min samples there is no number — never a single-sample median" do
    start_supervised!(FluxVale.PromEx)

    for _wake <- 1..4, do: emit_total("forgejo", 60.0)

    assert WakeStats.median_total_by_app() == %{}
  end

  test "everything past the last bucket reports that bucket — the honest floor" do
    start_supervised!(FluxVale.PromEx)

    for _wake <- 1..5, do: emit_total("slowpoke", 200.0)

    medians = WakeStats.median_total_by_app()

    assert Map.fetch!(medians, "slowpoke") == 180.0
  end

  test "the TTL cache serves the stale map until it lapses" do
    with_ttl(60)

    # The named server outlives the test — a sibling test's fresh map
    # is legitimately servable under the raised TTL. Start from a
    # known-cold cache (OTP tooling, not an app backdoor).
    :sys.replace_state(WakeStats, fn _state -> %{computed_at: nil, medians: %{}} end)

    start_supervised!(FluxVale.PromEx)

    for _wake <- 1..5, do: emit_total("kavita", 6.0)

    assert %{"kavita" => _estimate} = WakeStats.median_total_by_app()

    %{computed_at: computed_at} = :sys.get_state(WakeStats)

    # Samples landing after the cached computation must not leak into
    # the answer until the TTL lapses — the badge quotes a minute-stale
    # truth by design.
    for _wake <- 1..5, do: emit_total("forgejo", 30.0)

    medians = WakeStats.median_total_by_app()

    refute Map.has_key?(medians, "forgejo")
    assert %{computed_at: ^computed_at} = :sys.get_state(WakeStats)
  end
end
