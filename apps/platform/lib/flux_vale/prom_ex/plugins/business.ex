defmodule FluxVale.PromEx.Plugins.Business do
  @moduledoc """
  The alert-worthy business counters — the fleet subset of the
  business-telemetry seams (the LiveDashboard definitions in
  FluxValeWeb.Telemetry are the other consumer of the same
  emissions). Counters only: alerts read rates and occupancy, never
  latencies — wake latency stays Plugins.Wake's histograms.

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

  Cardinality is a closed ceiling, seeded at 0 from boot
  (PromEx.SeedBusinessCounters): 42 legal instance pairs
  (instance_transition_pairs/0) + 20 gateway pairs
  (gateway_state_pairs/0) + 6 backup outcomes
  (backup_outcome_pairs/0) = 68 steady-state series. Seeding because
  increase() never counts a series' first increment — Prometheus
  anchors on the first scrape and assumes no preceding zero, so a
  series that materializes on its first real event loses that event;
  with in-memory counters resetting per deploy, that is each edge's
  first event after every deploy — exactly what the occupancy rules
  must see.

  The families are Telemetry.Metrics **sum** metrics (measurement
  :count), not counter metrics — required for that seed: a counter
  counts events (+1 per emission, the measurement ignored), so a
  zero-seed through one would inflate every series by one per boot
  (+5 phantom error-occupancy per deploy on the instance funnel). A
  sum accumulates the measurement — the emitters' count-1 events
  accumulate identically, count-0 seeds materialize the series at 0
  — and the exporter renders the same names with TYPE counter (sum's
  PromEx default), so the scrape contract is byte-identical.

  No signup metric fleet-side: no alert consumes it (alert-worthy
  only — the ruling), LiveDashboard shows it. The `flux_vale_*_total`
  families are the naming contract the fleet PR's allowlist cites;
  nothing may rename them silently.
  """

  use PromEx.Plugin

  alias FluxVale.Infrastructure.BackupRun.OutcomeMarkers
  alias FluxVale.Infrastructure.Instance.StatusTransition
  alias FluxVale.Infrastructure.Types.AccessGatewayState
  alias FluxVale.Infrastructure.Types.BackupRunKind

  @gateway_event [:flux_vale, :gateway, :state_change]
  @instance_event [:flux_vale, :instance, :status_transition]
  @run_event [:flux_vale, :backup, :run]

  @doc """
  Every legal instance (from, to) pair — StatusTransition's table
  plus the any→:error / any→:deleting catch-all arms, from ≠ to:
  42 pairs. Derived, never restated — the validator stays the one
  writer of the machine.
  """
  @spec instance_transition_pairs() :: [{atom(), atom()}]
  def instance_transition_pairs do
    transitions = StatusTransition.valid_transitions()

    table_pairs = for {from, tos} <- transitions, to <- tos, do: {from, to}

    states = Map.keys(transitions)

    catch_all_pairs = for from <- states, to <- [:error, :deleting], from != to, do: {from, to}

    (table_pairs ++ catch_all_pairs)
    |> MapSet.new()
    |> Enum.sort()
  end

  @doc """
  Every ordered gateway (from, to) pair — the closed five-state
  enum, from ≠ to: 20 pairs (occupancy reads entries minus exits
  for every state, so no pair is skippable).
  """
  @spec gateway_state_pairs() :: [{atom(), atom()}]
  def gateway_state_pairs do
    states = AccessGatewayState.values()

    for from <- states, to <- states, from != to do
      {from, to}
    end
  end

  @doc """
  Every backup (kind, status) pair — the kind enum × the terminal
  statuses (OutcomeMarkers owns terminality): 6 pairs.
  """
  @spec backup_outcome_pairs() :: [{atom(), atom()}]
  def backup_outcome_pairs do
    for kind <- BackupRunKind.values(), status <- OutcomeMarkers.terminal_statuses() do
      {kind, status}
    end
  end

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
          # sum, not counter — the moduledoc's seeding note: the
          # measurement accumulates (a count-0 seed materializes the
          # series at 0), and every real emitter carries count 1.
          sum(
            metric_prefix ++ [:instance, :status_transition_total],
            event_name: @instance_event,
            description:
              "Instance status transitions by from/to — the lifecycle funnel (reason is dashboard-only fleet-side).",
            measurement: :count,
            tags: [:from, :to]
          ),
          sum(
            metric_prefix ++ [:gateway, :state_change_total],
            event_name: @gateway_event,
            description:
              "Access-gateway state changes by from/to — the billing switch (ladder suspends vs observed failures).",
            measurement: :count,
            tags: [:from, :to]
          ),
          sum(
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
