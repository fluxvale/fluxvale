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
  - `flux_vale_instances_in_error` — the DB-truth stuck-in-error
    gauge (#182), one poller sample per 60s: instances whose status is
    `:error` NOW with `errored_at` inside the 7d window (StatusMarkers
    stamps the entry, clears the exit). Label-free — the count is the
    alert's subject, and the rendered name is the cross-repo contract
    with the fleet allowlist and the replacement occupancy rule (infra
    #182); a gauge, so no `_total` suffix. NULL/old `errored_at` fail
    the window comparison and are excluded — an unknown or stale entry
    time must never page (the Oct-23 zombie rows' whole lesson).

  Cardinality is a closed ceiling for the counters, seeded at 0 from
  boot (PromEx.SeedBusinessCounters): 52 legal instance pairs
  (instance_transition_pairs/0) + 20 gateway pairs
  (gateway_state_pairs/0) + 6 backup outcomes
  (backup_outcome_pairs/0) = 78 steady-state series. Seeding because
  increase() never counts a series' first increment — Prometheus
  anchors on the first scrape and assumes no preceding zero, so a
  series that materializes on its first real event loses that event;
  with in-memory counters resetting per deploy, that is each edge's
  first event after every deploy — exactly what the occupancy rules
  must see. The gauge adds one label-free series per platform pod —
  79 steady-state series per pod — and is NOT seeded: the poller
  materializes it within one 60s tick of boot, and a count gauge needs
  no first-increment anchor (each sample is the whole truth, not a
  delta).

  The `flux_vale_*_total` families are Telemetry.Metrics **sum**
  metrics (measurement :count), not counter metrics — required for
  that seed: a counter
  counts events (+1 per emission, the measurement ignored), so a
  zero-seed through one would inflate every series by one per boot
  (+4 phantom error-occupancy per deploy on the instance funnel —
  9 seeded entries vs 5 exits). A sum accumulates the measurement —
  the emitters' count-1 events accumulate identically, count-0 seeds
  materialize the series at 0 — and the exporter renders the same
  names with TYPE counter (sum's PromEx default), so the scrape
  contract is byte-identical.

  No signup metric fleet-side: no alert consumes it (alert-worthy
  only — the ruling), LiveDashboard shows it. The `flux_vale_*_total`
  families are the naming contract the fleet PR's allowlist cites;
  nothing may rename them silently.
  """

  use PromEx.Plugin

  alias FluxVale.Infrastructure.BackupRun.OutcomeMarkers
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.StatusTransition
  alias FluxVale.Infrastructure.Types.AccessGatewayState
  alias FluxVale.Infrastructure.Types.BackupRunKind

  # The gauge's filter expression (Ash.Query.filter's DSL variables).
  require Ash.Query

  @gateway_event [:flux_vale, :gateway, :state_change]
  @instance_event [:flux_vale, :instance, :status_transition]
  @run_event [:flux_vale, :backup, :run]

  # Singular segment for the event (the metric family is the plural
  # rendered name below — the two namespaces stay symmetric with the
  # other business events).
  @in_error_event [:flux_vale, :instance, :in_error]

  # The stuck-in-error window the gauge counts within (infra #182): an
  # episode that entered :error longer ago than this is a zombie for
  # paging purposes and must not contribute.
  @stuck_window_days 7

  # One sample per minute — the alert reads occupancy, not rate; finer
  # polling buys nothing at a 15m `for` and doubles the scrape load.
  @poll_rate 60_000

  @doc """
  Every legal instance (from, to) pair — StatusTransition's table
  plus the any→:error / any→:deleting catch-all arms, from ≠ to:
  52 pairs. Derived, never restated — the validator stays the one
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

  @impl PromEx.Plugin
  def polling_metrics(opts) do
    # Same prefix stance as event_metrics/1: the rendered
    # `flux_vale_instances_in_error` name is the cross-repo contract
    # (fleet allowlist + the replacement occupancy rule, infra #182).
    metric_prefix = Keyword.get(opts, :metric_prefix, [:flux_vale])

    Polling.build(
      :business_stuck_instances_polling_metrics,
      Keyword.get(opts, :poll_rate, @poll_rate),
      {__MODULE__, :execute_stuck_instances_metrics, []},
      [
        last_value(
          metric_prefix ++ [:instances, :in_error],
          event_name: @in_error_event,
          description:
            "Instances currently stuck in :error with an entry stamp inside the recent window — the DB-truth stuck-in-error gauge.",
          measurement: :count
        )
      ],
      # detach_on_error: false — the poller MFA reads the DB, and the
      # raw-MFA path (build's default) hands a raising measurement to
      # telemetry_poller, which permanently filters it from its state
      # on the first raise (make_measurements_and_filter_misbehaving —
      # verified in deps): one 60s tick during a CNPG restart would
      # kill the series for the pod's lifetime, and absent reads 0
      # under the alert's `or vector(0)` stance. The safe runner logs
      # and keeps polling, so last_value holds the last good sample
      # through a transient outage.
      detach_on_error: false
    )
  end

  @doc false
  @spec execute_stuck_instances_metrics() :: :ok
  def execute_stuck_instances_metrics do
    :telemetry.execute(@in_error_event, %{count: recent_error_count()}, %{})
  end

  @doc """
  The gauge's number: instances in `:error` NOW whose `errored_at` is
  inside the recent window. No labels, no `_total` — a gauge.

  Scoping is the point (infra #182): `errored_at > cutoff` excludes
  both the permanent zombies (stale stamps age out of the window) and
  the undated rows (NULL fails the comparison) — an unknown entry time
  must not page, so the conservative arm is the comparison itself.
  Strictly greater: an episode stamped at exactly `cutoff` (the 7d
  boundary) is already outside the window.
  """
  @spec recent_error_count() :: non_neg_integer()
  def recent_error_count do
    cutoff = DateTime.add(DateTime.utc_now(), -@stuck_window_days, :day)

    # Metrics polling has no actor — the gauge is a system-level read
    # (the seeds' authorize?: false stance).
    Instance
    |> Ash.Query.filter(status == :error and errored_at > ^cutoff)
    |> Ash.count!(authorize?: false)
  end
end
