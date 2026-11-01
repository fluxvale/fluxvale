defmodule FluxValeWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("flux_vale.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("flux_vale.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("flux_vale.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("flux_vale.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("flux_vale.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Business Metrics — one emission per seam, two consumers: these
      # definitions render in LiveDashboard (the NOW view); the
      # alert-worthy subset also flows to Grafana via PromEx's plugins
      # (Plugins.Wake / Plugins.Business) with deliberately narrower
      # labels. In-memory, resets per deploy — accepted. Buckets are
      # shared with the PromEx plugin (ONE list — Wake.buckets/0).
      #
      # Wake latency (the scale-to-zero SLI) — events fire from
      # Instance.WakeMarkers; only the definitions are new here.
      distribution("flux_vale_wake_promotion_wait_seconds",
        event_name: [:flux_vale, :wake, :promotion],
        measurement: :duration,
        description:
          "Wake request to Deployment scaled — the platform-owned part of a wake (p95 < 5s SLO).",
        reporter_options: [buckets: FluxVale.PromEx.Plugins.Wake.buckets()],
        tags: [:app],
        unit: :second
      ),
      distribution("flux_vale_wake_app_boot_seconds",
        event_name: [:flux_vale, :wake, :boot],
        measurement: :duration,
        description: "Deployment scaled to readiness — the app-owned part of a wake, per-app.",
        reporter_options: [buckets: FluxVale.PromEx.Plugins.Wake.buckets()],
        tags: [:app],
        unit: :second
      ),
      distribution("flux_vale_wake_total_seconds",
        event_name: [:flux_vale, :wake, :total],
        measurement: :duration,
        description: "Wake request to serving — the whole wake, per-app.",
        reporter_options: [buckets: FluxVale.PromEx.Plugins.Wake.buckets()],
        tags: [:app],
        unit: :second
      ),
      # Instance lifecycle outcomes (Instance.StatusMarkers on the
      # :update_status funnel) — reason is the deploy-failure triage
      # lens; labels are closed enums, cardinality bounded by the state
      # machine (~24 series).
      counter("flux_vale_instance_status_transition_count",
        event_name: [:flux_vale, :instance, :status_transition],
        measurement: :count,
        description: "Instance status transitions, by from/to/reason (the lifecycle funnel).",
        tags: [:from, :to, :reason]
      ),
      # Gateway state changes (AccessGateway.StateMarkers on the five
      # state-writing actions) — ladder suspends vs observed failures,
      # ~10 series.
      counter("flux_vale_gateway_state_change_count",
        event_name: [:flux_vale, :gateway, :state_change],
        measurement: :count,
        description: "Access-gateway state changes, by from/to (the billing switch).",
        tags: [:from, :to]
      ),
      # Backup/restore outcomes (BackupRun.OutcomeMarkers on :update,
      # terminal finalizes only) — 6 series + 3 for the duration
      # summary's kinds.
      counter("flux_vale_backup_run_count",
        event_name: [:flux_vale, :backup, :run],
        measurement: :count,
        description: "Backup/restore runs reaching a terminal status, by kind and status.",
        tags: [:kind, :status]
      ),
      summary("flux_vale_backup_duration_seconds",
        event_name: [:flux_vale, :backup, :run],
        measurement: :duration,
        description: "Terminal backup/restore duration (started_at → finished_at), by kind.",
        tags: [:kind],
        unit: :second
      ),
      # Signups (VerifyAuthCode's JIT arm — seed/admin creates never
      # pass through it) — one series.
      counter("flux_vale_identity_signup_count",
        event_name: [:flux_vale, :identity, :signup],
        measurement: :count,
        description: "JIT account creations — the signup rate."
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {FluxValeWeb, :count_users, []}
    ]
  end
end
