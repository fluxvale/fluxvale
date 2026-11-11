# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# "json" maps to the JSON:API media type (per the ash_json_api
# installer) — the :api pipeline's accepts ["json"] negotiates
# application/vnd.api+json through it. ONE types map per config call:
# a second config call's :types REPLACES this one (no deep merge
# across calls). Mime compiles this table, so it must exist before
# the first build (adding it later needs `mix deps.clean mime
# --build`).
config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :spark,
  formatter: [
    "Ash.Resource": [
      section_order: [:authentication, :token, :user_identity, :json_api, :admin, :postgres]
    ],
    "Ash.Domain": [section_order: [:json_api, :admin]]
  ]

config :ash, known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]
# Required by ash 3.33.0 (CVE-2026-82752, GHSA-cwjv-574p-59f6): count string
# length in codepoints, matching the SQL data layer, so max_length bounds
# stored size (graphemes let combining-mark strings pass unbounded).
config :ash, default_string_length_count: :codepoints

config :flux_vale,
  ecto_repos: [FluxVale.Repo],
  # Ash domain registry — first domain landed with Identity (#20). The
  # AshAdmin mount exposes a domain iff its `admin show?` is set
  # (opt-in, ADR-0027 §3): Ops #25, Catalog #70, Infrastructure #72,
  # Pricing #125, Billing #140 (the goodwill-credit surface: wallet +
  # ledger only, Topup excluded), Feedback #412 (the public board's
  # data: reads are public by policy, posts/votes run the paying gate,
  # comments open to any authenticated user per the owner's Nov ruling,
  # moderation admin-gated — safe to render on a mount the admin gate
  # already fronts). Identity stays
  ash_domains: [
    FluxVale.Identity,
    FluxVale.Accounts,
    FluxVale.Billing,
    FluxVale.Ops,
    FluxVale.Catalog,
    FluxVale.Infrastructure,
    FluxVale.Pricing,
    FluxVale.Api,
    FluxVale.Feedback
  ],
  generators: [timestamp_type: :utc_datetime],
  # AccessRules snapshot TTL (#26, settled): 60s — the cross-node
  # revocation bound; the mutating node busts instantly (BustCache).
  # 0 in test.exs disables the cache (instant consistency per test).
  access_rules_cache_ttl_seconds: 60,
  # Instance ingress base domain (#73): <subdomain>.<base> routes via the
  # namespace's IngressRoute. Local = the lvh.me wildcard (ADR-0020);
  # M4's runtime.exs override carries the prod domain.
  instances_base_domain: "fluxvale.lvh.me",
  # Env-scoped slug prefix (#155): prod (nil) mints bare labels; a
  # non-prod env sharing the wildcard sets INSTANCES_SLUG_PREFIX so it
  # can never take a prod label.
  instances_slug_prefix: nil,
  # Which platform env this app is (#196): stamped as the
  # fluxvale.io/platform-env label on every instance namespace at
  # deploy, and the orphan sweep only ever deletes namespaces carrying
  # ITS OWN value — staging and production share one physical cluster
  # (ADR-0010 same-box), so an unscoped sweep deleted namespaces it had
  # no row for (the Oct-21 incident: prod's sweep deleted staging's
  # instance). Runtime override PLATFORM_ENV per fleet overlay —
  # REQUIRED in :prod (an unset value would default both envs to this
  # same "local" and re-open the cross-env deletion); "local" is the
  # dev default.
  platform_env: "local",
  # The namespace edge ingress is admitted FROM in instance
  # NetworkPolicies (the Traefik chart's namespace locally; M4's fleet
  # repo overrides for prod — same override story as instance_rbac).
  instance_ingress_namespace: "traefik",
  # The per-namespace RoleBinding #73's deploy trigger applies
  # (deploy/local/k8s/01-platform-rbac.yaml): the platform's own SA,
  # bound to the workload ClusterRole inside each instance namespace.
  # M4's fleet repo carries the prod values (runtime override).
  instance_rbac: [
    service_account: "fluxvale-platform",
    service_account_namespace: "fluxvale-dev",
    workload_role: "fluxvale-platform-workload"
  ],
  # File access (#190, ADR-0035): file-access instances get an rclone
  # WebDAV sidecar serving the app's data volume at the instance
  # hostname's path prefix. The image pin is a deliberate bump (supply
  # chain); port/path/username feed both the deploy op and the instance
  # page's credential panel — one source of truth.
  file_access: [
    image: "rclone/rclone:1.75.2",
    port: 8080,
    path_prefix: "/dav",
    username: "fluxvale"
  ],
  # Instance backups (#222, ADR-0037): a restic Job in the instance
  # namespace writes snapshots to the user's own S3-compatible bucket.
  # The image pin is a deliberate supply-chain bump; the requests are
  # platform overhead on top of the purchased allocation, so the
  # namespace ResourceQuota widens by exactly this (limits ride the
  # builders' 2x-requests convention) and DeployInstance re-applies the
  # same margin — one source of truth for the Job spec and the quota.
  # `cpu_cores` must stay a STRING: the quota math does `Decimal.new/1`,
  # which rejects floats (that is the point — no float rounding in a
  # quota that has to cover the pod's exact request).
  backups: [
    image: "restic/restic:0.19.1",
    cpu_cores: "0.1",
    memory_mb: 128,
    # v1's daily window (ADR-0037 §3): 03:00 UTC plus a per-instance
    # minute jitter derived from the id — the user controls enabled and
    # retention, not the clock.
    schedule_hour: 3,
    # The Job's activeDeadlineSeconds — the k8s-side bound that turns a
    # hung run into a Job failure the watch pass finalizes.
    timeout_seconds: 2 * 60 * 60,
    # The restore Job's own deadline (ADR-0037 §5). Deliberately longer
    # than the backup's: a restore downloads every chunk of the snapshot
    # and then reads it back (--verify), where a backup uploads only what
    # changed. One shared key would either kill large restores or loosen
    # the hang bound on the backup path.
    restore_timeout_seconds: 4 * 60 * 60,
    # How long a restore waits for the app's pods to actually terminate
    # after scaling to 0 (ADR-0037 §5): `scale` returns when the API
    # accepts the count, and restic's `--delete` must not run against a
    # live writer. A Deployment's rollout finishes in seconds; two
    # minutes is the honest ceiling before the restore declares "could
    # not stop the app" and backs out.
    scale_down_timeout_seconds: 120,
    # How long the restore waits for a deleted leftover Job OBJECT to be
    # gone before applying the new one: a delete that returns 202 is
    # still terminating, and an SSA onto it 4xxs. The API garbage-collects
    # a Job in seconds once its pods are gone.
    job_delete_timeout_seconds: 15,
    # The watch pass's own bound, above the Job's deadline on purpose: the
    # Job's failure reports through the normal outcome path first, and
    # only a run whose Job vanished entirely reaches this horizon (or its
    # slot would never free). Above the LONGEST deadline (restore's) for
    # the same reason.
    stale_after_seconds: 5 * 60 * 60
  ],
  # Bundled backing services (#612, ADR-0045): the platform's
  # approved-image registry (D2) — entries declare MAJORS, this maps
  # each kind+major to the exact-pinned image and per-kind constants;
  # one approved major per kind at launch (the smallest closed set;
  # more join by deliberate registry growth). Pin choices verified
  # 2026-11-08: postgres 18 = current stable major (19 GA lands
  # 2026-11-19) and what Docmost's and Vikunja's official composes
  # ship, above Umami's 12.14 minimum; redis 8 = Docmost's official
  # compose. Exact tags + digests verified against registry-1.docker.io
  # (the #587 upstream-facts discipline). Tag pins, never `:latest` —
  # the house convention (file_access/backups); a re-pushed tag can't
  # shift a live instance because the S2 create-time snapshot resolves
  # the ref onto the Instance. `cpu` must stay a STRING —
  # the quota math does `Decimal.new/1`, which rejects floats (the
  # backups stance). The requests are carved from the purchased
  # allocation, NOT added on top (D1: PG 0.10/256, Redis 0.05/64).
  backing_services: [
    postgres: %{
      "18" => %{image: "postgres:18.6-alpine3.24", port: 5432, cpu: "0.10", memory_mb: 256}
    },
    redis: %{
      "8" => %{image: "redis:8.10.3-alpine3.23", port: 6379, cpu: "0.05", memory_mb: 64}
    }
  ],
  # Scale-to-zero (#203, ADR-0036). idle threshold = the settled owner
  # number (1h); probe user-agents never count as traffic (settled) —
  # the beacon filters them before the idle clock. E2E shortens the
  # threshold via runtime.exs (IDLE_SLEEP_AFTER_SECONDS).
  idle_sleep_after_seconds: 3600,
  edge_probe_user_agents: [
    ~r/\Akube-probe\//iE,
    ~r/\APrometheus\//iE,
    ~r/\ABlackbox-Exporter\//iE,
    ~r/\AUptimeRobot\//iE,
    ~r/\ABetter ?Uptime\//iE,
    ~r/\APingdom\.com\//iE,
    ~r/\ASite24x7\//iE,
    ~r/\AHetrixTools\//iE,
    ~r/\AUptime-Kuma\//iE
  ],
  # The activity beacon's target: the platform's own in-cluster
  # service. Namespace rides instance_rbac's service_account_namespace
  # (the same value the RoleBindings use — one source, and
  # INSTANCE_RBAC_SA_NAMESPACE overrides both at once).
  edge_beacon: [
    service: "fluxvale-platform",
    port: 4000
  ],
  # Private access (#268, ADR-0039): a per-org userspace tailscaled
  # gateway serving the org's private instances over the owner's tailnet.
  # The namespace is the platform's OWN (never an instance namespace —
  # the gateway must not live inside anything a customer workload owns,
  # ADR-0005 Am. 5). The image is pinned to an exact version like every
  # other image in this file: `:stable` is a moving tag, so a pod restart
  # (including the one on every key re-paste) could silently pull a
  # different tailscaled. Bump deliberately. The rate is a placeholder
  # here — the price is the owner's (§5's cost basis), the row snapshots
  # whatever the panel passes.
  access_gateway: [
    namespace: "fluxvale-access",
    image: "tailscale/tailscale:v1.90.6",
    monthly_cents: 200,
    # The wake intercept (#273, ADR-0039 §6) is live: a sleeping attached
    # instance's serve entry points at the platform's /internal/access
    # endpoint — the controller it addresses ships in the same PR — which
    # wakes the instance and flips the config back to the app once it is
    # running. The flag gates NEW asleep-target writes only: a row that
    # is already :sleeping keeps its platform target until its next
    # wake->sleep cycle (or a re-paste / detach-attach refresh) —
    # setting this false never unmounts the route.
    wake_intercept_enabled: true
  ],
  # Custom access domains (ADR-0040 S1): the owner registers their own
  # domain and the platform proves control by issuing a wildcard cert
  # through the delegated _acme-challenge record (verify-by-issuance).
  # `issuer` names the DNS-01 ClusterIssuer the fleet side owns (the
  # fleet PR creates it; this code only names it from here — staging's
  # Let's Encrypt endpoint is the dev-safe default, no rate limits).
  # `certificate_namespace` is the platform's own access namespace (the
  # gateway's). `issuance_deadline_hours` bounds the verify-by-issuance
  # wait: a :pending row with no Ready Certificate past it is :failed.
  # Runtime overrides wait for the fleet's env-var names (the
  # instances_base_domain wiring in runtime.exs is the pattern).
  access_domains: [
    issuer: "letsencrypt-staging",
    certificate_namespace: "fluxvale-access",
    issuance_deadline_hours: 72
  ],
  # Custom domains are free (ADR-0040 Amendment 2): no rate, no accrual,
  # no env override. Registration still needs a paid, topped-up account
  # (the register policy's entitlement gate).
  # Strong private access (ADR-0040 S3): the tunnel + resolution halves
  # of the gateway's tailnet work. `access_edge` is DEFAULTED at runtime
  # to the fleet's access entrypoint (infra #119 — runtime.exs; env
  # override wins), so nil here is only the pre-runtime value: the serve
  # config's tunnel limb is omitted when the key is ABSENT (pinned by
  # test), which is now only a deliberate Application-env deletion.
  # `access_dns` stays nil-for-dev: without a resolver IP nothing
  # claims (`:resolver_unconfigured`), so the tunnel limb is inert on a
  # local stack. The fleet sets the resolver IP from env (runtime.exs —
  # the instances_base_domain pattern). `access_edge` names the Traefik
  # access entrypoint the gateway's raw 443/80 forward to (service = the
  # fully-qualified in-cluster DNS name); `access_dns` names the shared
  # resolver's ClusterIP (a fleet-reserved /32 — one Service IP, never a
  # wider slice, §12) and the zones ConfigMap the S4 renderer writes.
  # `tailscale_api` is the API surface claims are written through
  # (§5's token arrives pasted through SetAccessApiToken, never env).
  access_edge: nil,
  access_dns: nil,
  tailscale_api: [
    base_url: "https://api.tailscale.com"
  ],
  # One active payment provider (ADR-0029). Per-provider webhook routes
  # and config blocks make the gateway a one-module swap. Polar is the
  # default (#377). HitPay stays configured and one env-dial away
  # (PAYMENTS_PROVIDER=hitpay per environment) plus one config revert.
  # Credentials arrive via env (runtime.exs, ADR-0021), never here.
  payments_provider: FluxVale.Billing.Providers.Polar,
  hitpay: [
    # The first implementation (Am. 2). base_url defaults to the
    # sandbox, and the production URL is only set when the
    # registrations gate (#142) lifts.
    base_url: "https://api.sandbox.hit-pay.com",
    # Checkout offers exactly these methods, sent as repeatable
    # payment_methods[] entries (#364). Cards-only is the owner
    # decision (Nov 2026) and stays the default even after the account
    # activates more — widening is an explicit config change, never a
    # default flip. HITPAY_PAYMENT_METHODS overrides at runtime.
    payment_methods: ["card"]
  ],
  # The second provider (#377) — sandbox default, production flips
  # via POLAR_SERVER at the gated cutover. Credentials arrive via
  # env (runtime.exs, ADR-0021 Am. 3) — never here.
  polar: [
    # #377: buyer-entered codes off by default — the pre-discount
    # subtotal mapping would credit full gross on a discounted
    # charge; the no-real-charge e2e enables it per the runbook.
    allow_discount_codes: false,
    server: "sandbox"
  ],
  # The minimum wallet top-up (#250 S6, ratified 2026-11-10). Polar Pro
  # charges $0.40 per checkout, so a floor keeps the fixed fee from
  # eating a small lane's margin: at $5 the marginal storage rate still
  # clears 41.4% gross (45.4% at $10, rejected for early-stage
  # friction). The wizard, its copy, and the paid-feature prompts all
  # read this one value; StartTopup enforces it server-side.
  billing: [min_topup_cents: 500]

# Storage beyond the self-service threshold (#250, ADR-0046): the ladder
# tops out at 100 GB self-service; above it a member requests a target
# total and an operator procures the capacity before approving. The first
# `threshold_gb` prices on the v5 curve as today; each GB above bills at
# `cents_per_gb` — a COGS pass-through plus margin, deliberately NOT a
# market-curve term (the regional surcharge never multiplies it). The
# threshold is parity-pinned to AllocationSliders' top storage rung by
# test; `max_gb` is the attachable ceiling, not a ladder value.
config :flux_vale, :storage_beyond_threshold, %{
  threshold_gb: 100,
  # Ratified 2026-11-10 (#250 S6) on the Polar Pro fee model: 3c/GB/mo
  # holds 45-48% gross at realistic top-ups (ADR-0046 Am. 1).
  cents_per_gb: 3,
  max_gb: 7_600
}

# SEO canonical identity (#164, ADR-00025): canonical links, og:url, the
# sitemap and the noindex host check all read these — the prod origin is
# the truth regardless of the serving host (staging serves prod URLs by
# design). One place; helpers never hardcode either value.
canonical_origin = "https://fluxvale.com"

config :flux_vale,
  canonical_origin: canonical_origin,
  canonical_host: "fluxvale.com"

# #362 (OQ #9): the single seeded first-party device-flow client — the
# CLI's constant. There is no client registry table (OQ #9's deferred
# upgrade half); until it lands this value IS the registry, and the
# device endpoints validate against it (FirstPartyClient).
config :flux_vale, :device_flow_client_id, "fluxvale-cli"

# Site analytics (#576): the public layout's Umami wiring. nil until
# runtime.exs sees BOTH UMAMI_SCRIPT_URL and UMAMI_WEBSITE_ID — nil
# renders no script at all, so every env stays silent until an operator
# deliberately configures it. Read at render time
# (FluxValeWeb.SiteAnalytics), never at compile time.
config :flux_vale, :site_analytics, nil

# #671's residue close (ADR-0027 Am. 6): the periodic demotion
# re-resolve cadence on the generated admin tools (ash_admin +
# live_dashboard live_sessions) — a demoted platform admin's open tab
# redirects to /sign-in within this window because its cid-targeted
# events can never cross a view-level hook. 30s is the owner's Nov 11,
# 2026 call. Read per arm (FluxValeWeb.AdminDemotionRecheck), so a
# put_env on a live node applies within one tick; an env-var override
# in runtime.exs can be added when a deployment actually needs one.
config :flux_vale, :admin_demotion_recheck_ms, 30_000

# Configure the endpoint
config :flux_vale, FluxValeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FluxValeWeb.ErrorHTML, json: FluxValeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FluxVale.PubSub,
  live_view: [signing_salt: "YdDkESt8"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Gettext default locale for the web backend: config, not library
# default — switching the default later is this config + PO files
# (FluxValeWeb.Locale resolves against the same backend).
config :flux_vale, FluxValeWeb.Gettext, default_locale: "en"

# The gateway auth key joins the default password filter (#273): LiveView
# logs event params at debug level, and the key is write-only — no path
# may echo it back (ADR-0039 §4), debug logs included (dev-only exposure;
# prod logs at :info).
config :phoenix, :filter_parameters, ["password", "auth_key"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally — read them in the admin-gated TestInbox at "/test-inbox" (#22),
# or via the machine surface: /test-inbox/api/mails (admin PAT).
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :flux_vale, FluxVale.Mailer, adapter: Swoosh.Adapters.Local

# The gated TestInbox (#22): non-prod mail capture + viewer. Routes are
# compiled into every build and gated by a runtime plug — staging flips
# the same release via TEST_INBOX_ENABLED (runtime.exs, ADR-0010's
# same-image rule); prod leaves it unset, so the surface 404s = absent.
# storage_driver is the M4 seam (ADR-0023 Am. 3): swap Memory for a
# DB-backed dev adapter without touching the endpoint or the tests.
config :flux_vale, :test_inbox,
  enabled: false,
  storage_driver: Swoosh.Adapters.Local.Storage.Memory

# The storybook workshop (#178) — same gate shape as the TestInbox
# above: compiled into every release, 404s until STORYBOOK_ENABLED
# flips it (runtime.exs; the fleet attaches the internal hostname
# where it runs). Dev overrides to on.
config :flux_vale, :storybook_enabled, false

# AshOban: open-source Oban, not Pro (v1's stance, kept)
config :ash_oban, :pro?, false

# Configure Oban: the repo-backed job queue. AshOban.config/2 (in
# application.ex) scans the ash domains for triggers and merges their
# schedules into this base — #73's Instance lifecycle is the first
# trigger consumer; the janitor (token pruning, daily 03:00 UTC) stays
# plain Oban.
config :flux_vale, Oban,
  repo: FluxVale.Repo,
  # `gateway_observe` is separate from `reconciler` on purpose: the
  # instance reconciler is the ONLY writer of `:running`, and it has
  # concurrency 1. Sharing that slot with a per-minute Deployment GET per
  # gateway would let observation traffic delay instance status writes —
  # a starvation risk, not just a throughput ceiling. 5 concurrent GETs
  # is plenty (each job is one read plus at most one row write) and stays
  # small enough that it cannot swamp the API server.
  queues: [
    deployments: 10,
    reconciler: 1,
    gateway_observe: 5,
    settler: 1,
    janitor: 1,
    billing: 1,
    backups: 1
  ],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", FluxVale.Janitor.PruneExpiredTokens},
       # #360 slice 3: the rate-limit window sweep, daily at 03:15 —
       # off the 03:00 token prune (queue concurrency is 1; the stagger
       # keeps the pair from bunching behind one lock).
       {"15 3 * * *", FluxVale.Janitor.PruneRequestWindows},
       # #360 slice 5: the audit-event sweep, daily at 03:30 — off
       # 03:00 (token prune) and 03:15 (windows) for the same reason;
       # the janitor trio staggers behind one queue lock.
       {"30 3 * * *", FluxVale.Janitor.PruneAuditEvents},
       # #362: the device-code sweep, daily at 03:45 — off 03:00/03:15/
       # 03:30 (same queue, same one-lock stance; the janitor quartet
       # staggers).
       {"45 3 * * *", FluxVale.Janitor.PruneDeviceCodes},
       # #124's ladder sweep, hourly at :07 — off the top-of-hour rush
       # (#113's stance; the reconciler minute-tick and smoke crons sit
       # there).
       {"7 * * * *", FluxVale.Workers.ZeroBalanceSweep},
       # #154's stranded-instance sweeper, hourly at :13 — off :07 and
       # the top of the hour (same stance).
       {"13 * * * *", FluxVale.Workers.StrandedInstanceSweep},
       # #364's stale top-up sweep, hourly at :17 — off :07 (zero
       # balance), :13 (stranded), and the top-of-hour rush (same
       # stance).
       {"17 * * * *", FluxVale.Workers.StaleTopupSweep},
       # #203's idle sweep, every 5 minutes — the 1-hour idle promise
       # rounds to at most threshold + one cadence (the minute-tick
       # reconciler already crosses the top of the hour every minute).
       # E2E compresses the cadence via runtime.exs
       # (IDLE_SWEEP_CRONEXPR) — #210 part 3; deployed envs keep this
       # default.
       {"*/5 * * * *", FluxVale.Workers.IdleInstanceSweep},
       # #222's backup sweep, every 5 minutes at :06/:11/… — the due and
       # watch passes are a fifth of the cadence's slack, and the offset
       # keeps it off the idle sweep's slots and the reconciler's tick
       # (#113's stance: nothing at the top of the hour).
       {"6-59/5 * * * *", FluxVale.Workers.BackupSweep},
       # ADR-0040 S1's verify-by-issuance pass, every 15 minutes at
       # :01/:16/:31/:46 — the top-of-hour :00 slot is deliberately
       # avoided by the neighbouring entries (#113's stance: nothing at
       # the top of the hour).
       {"1-59/15 * * * *", FluxVale.Janitor.VerifyAccessDomains}
     ]},
    # Retention for finished jobs (completed/cancelled/discarded) — v1
    # never pruned oban_jobs; adopted on review (#39). 7d keeps a
    # debugging window at a 1-job/day queue.
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  flux_vale: [
    args:
      ~w(js/app.js js/storybook.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  flux_vale: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Storybook CSS bundle (#178): storybook.css mirrors the app's token
# directives (it loads INSTEAD of app.css in the workshop) and scans
# the stories folder for utility usage. storybook_theme.css rethemes
# the workshop's own chrome (amber, not the shipped violet).
config :tailwind,
  storybook: [
    args: ~w(
      --input=assets/css/storybook.css
      --output=priv/static/assets/css/storybook.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  storybook_theme: [
    args: ~w(
      --input=assets/css/storybook_theme.css
      --output=priv/static/assets/css/storybook_theme.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  # otel_trace_id/otel_span_id land in Logger process metadata whenever a
  # span is current (the SDK stamps them on set_current_span) — the
  # log/trace correlation glue of ADR-0012 Am. 1. Lines outside any span
  # (e.g. Oban failure ERROR logs) stay uncorrelated until the Am. 2
  # structured formatter lands with the error-triage wiring.
  metadata: [:request_id, :otel_trace_id, :otel_span_id]

# OTEL (#98, ADR-0012 Am. 1): spans are created for every request and
# query, plus custom spans around the Instance deploy/reconcile
# orchestration. Export is a no-op unless OTEL_EXPORTER_OTLP_ENDPOINT is
# set — runtime.exs then points the batch processor's exporter at OTLP
# (in-cluster Alloy). OTEL_SERVICE_NAME (fleet overlays) names the
# service in Tempo.
config :opentelemetry,
  processors: [{:otel_batch_processor, %{exporter: :none}}]

# PostHog (ADR-0049): error tracking + server-side product events. The
# SDK's own auto-start stays off — the app owns the supervision tree
# (FluxVale.Application starts PostHog.Supervisor and the Logger handler
# itself, only when runtime.exs saw POSTHOG_API_KEY), so the kill switch
# is structural: unset means nothing starts. `enable` is a static
# never-auto-start decision, safe at compile time; everything
# env-dependent lives in runtime.exs.
# The source-context keys feed error-tracing stack frames and are read
# from the :posthog app env by `mix posthog.package_source_code` (the
# Dockerfile runs it before `mix release`). The root is scoped to lib/
# ON PURPOSE: mix release serializes compile-time app config into the
# release and rejects Regex terms there (the red-main lesson, #714) —
# so source_code_exclude_patterns must NOT be set as config. Scoping
# the root makes excludes unnecessary anyway: deps/, _build/, priv/ and
# test/ all sit BESIDE lib/, never under it, so the packaged map is our
# source and only our source.
config :posthog,
  enable: false,
  enable_source_code_context: true,
  root_source_code_paths: [Path.expand("../lib", __DIR__)],
  context_lines: 5

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
