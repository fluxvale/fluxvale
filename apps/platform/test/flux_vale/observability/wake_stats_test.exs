defmodule FluxVale.Observability.WakeStatsTest do
  @moduledoc """
  The catalog badge's derivation (#232): median total per app off the
  live scrape, PromQL-interpolated; the console wake widget's too
  (#702): p95 promotion per app. The two sample floors (median 5, p95
  20); the TTL cache and its snapshot seam; the down-tree {} posture.

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

  defp emit_promotion(app, duration) do
    :telemetry.execute([:flux_vale, :wake, :promotion], %{duration: duration}, %{app: app})
  end

  test "{} while the metrics tree is down" do
    assert WakeStats.median_total_by_app() == %{}
    assert WakeStats.p95_promotion_by_app() == %{}
    assert WakeStats.snapshot() == %{medians: %{}, p95_promotions: %{}}
  end

  # #611 S2: the public app page reads the same safe wrapper the
  # catalog index mounts through. The happy path answers the plain
  # call's map; the rescue/catch arms carry their coveralls
  # justification in the source.
  test "the safe wrapper answers the plain call's posture" do
    assert WakeStats.median_total_by_app_safe() == %{}
    assert WakeStats.p95_promotion_by_app_safe() == %{}
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

  test "an app with enough samples gets the interpolated p95 promotion" do
    start_supervised!(FluxVale.PromEx)

    # Twenty identical 3s promotions: everything lands in le=3, so the
    # interpolation walks (2, 3] — target rank 19 of 20 lands at
    # 2 + (3-2) * 19/20 = 2.95.
    for _wake <- 1..20, do: emit_promotion("kavita", 3.0)

    p95s = WakeStats.p95_promotion_by_app()

    assert_in_delta Map.fetch!(p95s, "kavita"), 2.95, 0.01
  end

  test "the p95's floor sits above the median's — 19 samples render one, hide the other" do
    start_supervised!(FluxVale.PromEx)

    # Nineteen wakes per family: the median renders (19 >= 5), the p95
    # stays hidden (19 < 20) — at this depth the 0.95 target rank lands
    # in the bucket holding the single largest observation, so the
    # "tail" would be one wake in costume.
    for _wake <- 1..19, do: emit_total("kavita", 6.0)
    for _wake <- 1..19, do: emit_promotion("kavita", 3.0)

    assert Map.has_key?(WakeStats.median_total_by_app(), "kavita")
    refute Map.has_key?(WakeStats.p95_promotion_by_app(), "kavita")
  end

  test "one refresh fills both maps — medians from total, p95s from promotion" do
    start_supervised!(FluxVale.PromEx)

    # The families must not cross: an app with only promotion samples
    # can never surface in the medians (its buckets never enter the
    # total pass), and kavita's numbers come from different series.
    for _wake <- 1..20, do: emit_promotion("promotion-only", 3.0)
    for _wake <- 1..20, do: emit_total("kavita", 6.0)
    for _wake <- 1..20, do: emit_promotion("kavita", 3.0)

    medians = WakeStats.median_total_by_app()
    assert_in_delta Map.fetch!(medians, "kavita"), 6.5, 0.01
    refute Map.has_key?(medians, "promotion-only")

    p95s = WakeStats.p95_promotion_by_app()
    assert_in_delta Map.fetch!(p95s, "kavita"), 2.95, 0.01
  end

  test "snapshot answers the pair from one refill — both maps share the stamp" do
    with_ttl(60)

    # Start from a known-cold cache (OTP tooling, not an app backdoor).
    :sys.replace_state(WakeStats, fn _state ->
      %{computed_at: nil, medians: %{}, p95_promotions: %{}}
    end)

    start_supervised!(FluxVale.PromEx)

    for _wake <- 1..20, do: emit_total("kavita", 6.0)
    for _wake <- 1..20, do: emit_promotion("kavita", 3.0)

    %{medians: medians, p95_promotions: p95s} = WakeStats.snapshot()
    assert_in_delta Map.fetch!(medians, "kavita"), 6.5, 0.01
    assert_in_delta Map.fetch!(p95s, "kavita"), 2.95, 0.01

    %{computed_at: computed_at} = :sys.get_state(WakeStats)

    # The pair is one computation: a second snapshot under the raised
    # TTL answers the same maps without a second walk — the console's
    # two columns can never quote different refills.
    assert %{medians: ^medians, p95_promotions: ^p95s} = WakeStats.snapshot()
    assert %{computed_at: ^computed_at} = :sys.get_state(WakeStats)
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
    # known-cold cache (OTP tooling, not an app backdoor); the state
    # carries both families since the shared-refill refactor.
    :sys.replace_state(WakeStats, fn _state ->
      %{computed_at: nil, medians: %{}, p95_promotions: %{}}
    end)

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

    # The refill is shared: the p95 call rides the same cached
    # computation — no second scrape walk, same stamp.
    assert WakeStats.p95_promotion_by_app() == %{}
    assert %{computed_at: ^computed_at} = :sys.get_state(WakeStats)
  end
end
