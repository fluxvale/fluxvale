defmodule FluxValeWeb.TelemetryTest do
  @moduledoc """
  The LiveDashboard contract for business telemetry: every event the
  seams fire has a definition here (a metric the dashboard never
  renders is a seam nobody wired), and every tag a definition declares
  resolves in the metadata the emission actually carries (a dangling
  tag silently drops the sample's label — the marker modules and these
  definitions must not drift apart).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.PromEx.Plugins.Wake
  alias FluxValeWeb.Telemetry

  # The metadata/measurements each business seam actually emits (the
  # marker modules' contract — WakeMarkers, StatusMarkers,
  # StateMarkers, OutcomeMarkers, VerifyAuthCode's JIT arm).
  @emitted %{
    [:flux_vale, :wake, :promotion] => {%{app: "kavita"}, %{duration: 1.5}},
    [:flux_vale, :wake, :boot] => {%{app: "kavita"}, %{duration: 6.0}},
    [:flux_vale, :wake, :total] => {%{app: "kavita"}, %{duration: 7.5}},
    [:flux_vale, :instance, :status_transition] =>
      {%{from: :deploying, to: :starting, reason: nil}, %{count: 1}},
    [:flux_vale, :gateway, :state_change] => {%{from: :active, to: :suspended}, %{count: 1}},
    [:flux_vale, :backup, :run] =>
      {%{kind: :scheduled, status: :succeeded}, %{count: 1, duration: 120.0}},
    [:flux_vale, :identity, :signup] => {%{}, %{count: 1}}
  }

  test "every business event has a definition whose tags and measurement resolve" do
    metrics = Telemetry.metrics()

    business_metrics = Enum.filter(metrics, &Map.has_key?(@emitted, &1.event_name))

    defined = MapSet.new(business_metrics, & &1.event_name)
    emitted_events = Map.keys(@emitted)
    expected = MapSet.new(emitted_events)

    assert MapSet.subset?(expected, defined)

    Enum.each(business_metrics, fn metric ->
      {metadata, measurements} = Map.fetch!(@emitted, metric.event_name)

      Enum.each(metric.tags, fn tag ->
        assert Map.has_key?(metadata, tag),
               "#{inspect(metric.event_name)}: tag #{inspect(tag)} missing from emitted metadata"
      end)

      assert Map.has_key?(measurements, metric.measurement),
             "#{inspect(metric.event_name)}: measurement #{inspect(metric.measurement)} not emitted"
    end)
  end

  test "the wake distributions share the PromEx plugin's one bucket list" do
    # Telemetry.Metrics normalizes string names to dot-split atom
    # lists — these one-segment names become single atoms.
    metrics = Telemetry.metrics()

    by_name =
      metrics
      |> Enum.map(fn metric -> {List.last(metric.name), metric} end)
      |> Map.new()

    for name <- [
          :flux_vale_wake_promotion_wait_seconds,
          :flux_vale_wake_app_boot_seconds,
          :flux_vale_wake_total_seconds
        ] do
      metric = Map.fetch!(by_name, name)

      assert metric.reporter_options[:buckets] == Wake.buckets()
      assert metric.tags == [:app]
      assert metric.unit == :second
    end
  end
end
