defmodule FluxVale.PromEx.Plugins.Wake do
  @moduledoc """
  #232's wake-latency histograms — the scale-to-zero SLI, per-app by
  design (a Kavita wake and a Forgejo wake differ by an order of
  magnitude; an averaged total would be a meaningless number).

  Three distributions over the same `app`-only label set (cardinality
  is a hard constraint — the Grafana free-tier series budget; every
  label value multiplies every bucket into a series):

  - `flux_vale_wake_promotion_wait_seconds` — wake request →
    Deployment scaled: the PLATFORM's part, the only cross-app
    aggregate the SLO owns (p95 < 5s).
  - `flux_vale_wake_app_boot_seconds` — scaled → ready: the APP's
    part, reported per-app, never promised.
  - `flux_vale_wake_total_seconds` — request → serving: the sum,
    per-app convenience for the dashboard and the catalog badge.

  Emitted by `FluxVale.Infrastructure.Instance.WakeMarkers` (see
  there for the clock semantics — boot includes reconcile-cadence
  latency on purpose).
  """

  use PromEx.Plugin

  @boot_event [:flux_vale, :wake, :boot]
  @promotion_event [:flux_vale, :wake, :promotion]
  @total_event [:flux_vale, :wake, :total]

  # Log-spaced over the wakes we know: promotion is sub-second to a
  # few seconds (sub-5s resolution carries the p95<5s SLO), boots run
  # ~6s (Kavita) to ~60s (Forgejo), 180s is pathological headroom.
  # Series math: 13 buckets +Inf/_sum/_count = 16 series per
  # histogram per app — 48 per app. Count the delta in the fleet PR
  # before touching this list.
  @buckets [0.5, 1, 2, 3, 5, 8, 12, 20, 30, 60, 90, 120, 180]

  # The ONE bucket list: FluxValeWeb.Telemetry's LiveDashboard
  # definitions share it so the dashboard's histograms and the fleet's
  # series resolve identically.
  @doc false
  @spec buckets() :: [number()]
  def buckets, do: @buckets

  @impl PromEx.Plugin
  def event_metrics(opts) do
    # Deliberately not the PromEx default prefix ([otp_app, :prom_ex,
    # :wake]): the stable flux_vale_wake_* name is what the fleet
    # dashboard, the SLO alert, and WakeStats' parser all cite —
    # deliberate evolution of the issue's fluxvale_wake_* sketch to
    # the otp_app's own spelling.
    metric_prefix = Keyword.get(opts, :metric_prefix, [:flux_vale, :wake])

    [
      Event.build(
        :wake_latency_event_metrics,
        [
          distribution(
            metric_prefix ++ [:promotion_wait, :seconds],
            event_name: @promotion_event,
            measurement: :duration,
            description:
              "Wake request to Deployment scaled (pod-creation ack) — the platform-owned part of a wake.",
            reporter_options: [buckets: @buckets],
            tags: [:app]
          ),
          distribution(
            metric_prefix ++ [:app_boot, :seconds],
            event_name: @boot_event,
            measurement: :duration,
            description:
              "Deployment scaled to readiness — the app-owned part of a wake, per-app, never averaged into an SLO.",
            reporter_options: [buckets: @buckets],
            tags: [:app]
          ),
          distribution(
            metric_prefix ++ [:total, :seconds],
            event_name: @total_event,
            measurement: :duration,
            description:
              "Wake request to serving — the whole wake, per-app (the dashboard's and the catalog badge's number).",
            reporter_options: [buckets: @buckets],
            tags: [:app]
          )
        ]
      )
    ]
  end
end
