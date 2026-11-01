defmodule FluxVale.PromEx.Plugins.Business do
  @moduledoc """
  The alert-worthy business counters — the fleet subset of the
  business-telemetry seams (the LiveDashboard definitions in
  FluxValeWeb.Telemetry are the other consumer of the same emissions).
  Counters only: alerts read rates and occupancy, never latencies —
  wake latency stays Plugins.Wake's histograms.

  Fleet labels are deliberately NARROWER than LiveDashboard's (per-
  consumer tag choice is the point of one emission): no `app` (a
  fleet-wide regression is what alerts, per-app is the dashboard's
  lens), no `reason` (no alert reads it — the instance from/to pair
  carries the occupancy math).

  - `flux_vale_instance_status_transition_total{from,to}` — the
    lifecycle funnel (Instance.StatusMarkers); the stuck-in-error
    occupancy alert reads `to="error"` vs `from="error"`.
  - `flux_vale_gateway_state_change_total{from,to}` — the billing
    switch (AccessGateway.StateMarkers); needs_attention occupancy.
  - `flux_vale_backup_run_total{kind,status}` — terminal backup/
    restore outcomes (BackupRun.OutcomeMarkers); the failure-rate
    alert's numerator and denominator.

  No signup metric fleet-side: no alert consumes it (alert-worthy
  only — the ruling), LiveDashboard shows it. The `flux_vale_*_total`
  families are the naming contract the fleet PR's allowlist cites;
  nothing may rename them silently.
  """

  use PromEx.Plugin

  @gateway_event [:flux_vale, :gateway, :state_change]
  @instance_event [:flux_vale, :instance, :status_transition]
  @run_event [:flux_vale, :backup, :run]

  @impl PromEx.Plugin
  def event_metrics(opts) do
    # Deliberately not the PromEx default prefix ([otp_app, :prom_ex]):
    # the stable flux_vale_* family names are what the fleet allowlist
    # and the alert rules query (the Plugins.Wake stance).
    metric_prefix = Keyword.get(opts, :metric_prefix, [:flux_vale])

    [
      Event.build(
        :business_event_metrics,
        [
          counter(
            metric_prefix ++ [:instance, :status_transition_total],
            event_name: @instance_event,
            description:
              "Instance status transitions by from/to — the lifecycle funnel (reason is dashboard-only fleet-side).",
            measurement: :count,
            tags: [:from, :to]
          ),
          counter(
            metric_prefix ++ [:gateway, :state_change_total],
            event_name: @gateway_event,
            description:
              "Access-gateway state changes by from/to — the billing switch (ladder suspends vs observed failures).",
            measurement: :count,
            tags: [:from, :to]
          ),
          counter(
            metric_prefix ++ [:backup, :run_total],
            event_name: @run_event,
            description:
              "Terminal backup/restore outcomes by kind/status — the failure-rate alert's fraction.",
            measurement: :count,
            tags: [:kind, :status]
          )
        ]
      )
    ]
  end
end
