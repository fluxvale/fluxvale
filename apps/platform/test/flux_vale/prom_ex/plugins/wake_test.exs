defmodule FluxVale.PromEx.Plugins.WakeTest do
  @moduledoc """
  #232's histogram contract: three distributions, `app`-only tags, the
  bucket set — and an end-to-end scrape proving the events land as
  `flux_vale_wake_*_seconds` series (the names the fleet dashboard
  and the SLO alert query; nothing may rename them silently).
  """

  # async: false — the scrape starts the module-named PromEx tree,
  # which is VM-global (one instance of the named processes).
  use FluxVale.DataCase, async: false

  alias FluxVale.PromEx.Plugins.Wake

  @bucket_line ~r/^flux_vale_wake_(promotion_wait|app_boot|total)_seconds_bucket\{app="kavita",le="8"\} \d+$/

  test "three app-tagged histograms over the documented buckets" do
    assert [%PromEx.MetricTypes.Event{metrics: distributions}] =
             Wake.event_metrics(otp_app: :flux_vale)

    assert length(distributions) == 3

    by_name = Map.new(distributions, fn dist -> {dist.name, dist} end)

    promotion = Map.fetch!(by_name, [:flux_vale, :wake, :promotion_wait, :seconds])
    boot = Map.fetch!(by_name, [:flux_vale, :wake, :app_boot, :seconds])
    total = Map.fetch!(by_name, [:flux_vale, :wake, :total, :seconds])

    assert promotion.event_name == [:flux_vale, :wake, :promotion]
    assert boot.event_name == [:flux_vale, :wake, :boot]
    assert total.event_name == [:flux_vale, :wake, :total]

    Enum.each([promotion, boot, total], fn dist ->
      assert dist.tags == [:app]
      assert dist.measurement == :duration
      assert dist.reporter_options[:buckets] == [0.5, 1, 2, 3, 5, 8, 12, 20, 30, 60, 90, 120, 180]
    end)
  end

  test "a wake's events land in the scrape as flux_vale_wake_* series" do
    start_supervised!(FluxVale.PromEx)

    :telemetry.execute([:flux_vale, :wake, :promotion], %{duration: 1.5}, %{app: "kavita"})
    :telemetry.execute([:flux_vale, :wake, :boot], %{duration: 6.0}, %{app: "kavita"})
    :telemetry.execute([:flux_vale, :wake, :total], %{duration: 7.5}, %{app: "kavita"})

    scrape = PromEx.get_metrics(FluxVale.PromEx)

    bucket_lines =
      scrape
      |> String.split("\n", trim: true)
      |> Enum.filter(&Regex.match?(@bucket_line, &1))

    # One le="8" bucket line per histogram — all three families carry
    # the app label the dashboard groups by.
    assert length(bucket_lines) == 3
    assert scrape =~ "flux_vale_wake_promotion_wait_seconds_count"
    assert scrape =~ "flux_vale_wake_app_boot_seconds_count"
    assert scrape =~ "flux_vale_wake_total_seconds_count"
  end
end
