# Observability

Status: Accepted (see [adr/](adr/) — [ADR-0012](adr/00012-observability-grafana-cloud.md), as amended).

## Stack

- **Grafana Alloy agent** in-cluster (~100 MB) shipping to **Grafana
  Cloud free tier** (hosted LGTM). Self-hosting rejected — ADR-0012's
  decisive argument (blind-when-the-box-dies), cost math, and the lab
  compromise (full LGTM in the local k3d cluster for learning,
  [ADR-0020](adr/00020-local-dev-parity.md); production home someday =
  the demoted box).
- **Error tracking**: **Grafana-first** — structured ERROR logs (Loki)
  + Tempo exception events + LogQL triage; a dedicated tracker
  deferred to the triage-volume trigger
  ([ADR-0012](adr/00012-observability-grafana-cloud.md) Am. 2).
- **Outside-in, layered**: Grafana Synthetic Monitoring (day one) —
  multi-region `/health` + DNS probes; **scheduled Bruno** (30–60 min)
  as the deep, authenticated correctness layer
  ([ADR-0011](adr/00011-simultaneous-deploy-post-deploy-smoke.md) Am. 1).

## The complete visibility inventory

OTEL + Alloy is the spine; "complete" means these sources and glue:

| Layer | Source | Notes |
|---|---|---|
| App metrics | **PromEx** (Phoenix/Ecto/Oban/BEAM, prebuilt dashboards) | OTLP-for-traces-and-logs + Prometheus-for-metrics is the standard split — Elixir OTEL metrics is weaker than PromEx |
| Cluster metrics | cAdvisor (free with kubelet) | per-instance CPU/RAM/disk |
| K8s object metrics | **kube-state-metrics** (fleet repo) | Alloy scrapes but doesn't generate |
| Node metrics | **node-exporter** (fleet repo) | disk fill, memory pressure |
| App logs | structured JSON on stdout | Alloy collects + enriches with k8s metadata |
| System logs | Talos kernel/kubelet/etcd | Alloy wiring for Talos host logs |
| Request traces | OTEL SDK (`opentelemetry_phoenix`/`_ecto`) → OTLP → Tempo | |
| **Deploy-pipeline traces** | **custom spans** around Instance deploy/reconcile orchestration | the product's most valuable trace: Oban trigger → namespace → apply → reconcile → running |
| Correlation glue | Logger formatter stamping trace/span IDs into every log line | makes the three pillars one narrative |
| **Domain sight** | Grafana **Postgres datasource** + dashboards over the wallet ledger, settlement runs, instance-state distribution | queries on our own DB; for a PaaS operator often the most important dashboard |
| App runtime introspection | **Phoenix LiveDashboard** (dev-open, prod admin-gated) | complements Grafana: trend/alert vs. this-node-right-now |
| Errors | Grafana-first: ERROR logs in Loki + Tempo exception events; LogQL triage with `error_signature` label | label = exception module, never the message (cardinality); dedicated tracker deferred (ADR-0016 trigger) |
| Outside-in | Grafana Synthetics (availability) + scheduled Bruno (authenticated correctness) | layered per ADR-0011 Am. 1 |

Emission rules: no OTLP log-push from Elixir (immature) — stdout JSON
is the battle-tested path. Customer instances get **metrics only** (no
customer log content ships to the third party — ADR-0012's data rule).

## Day-one checklist

**App (`mix.exs`, first release)**: `opentelemetry`,
`opentelemetry_exporter`, `opentelemetry_phoenix`,
`opentelemetry_ecto`, `prom_ex`; Logger formatter with trace/span IDs
**and exception fields** (module/message/stacktrace, user context);
custom span wrappers for Instance deploy + reconcile.

**Fleet repo**: Alloy config (scrape `/metrics` + k8s integrations +
OTLP receiver + Talos host logs); kube-state-metrics + node-exporter
charts; Grafana Cloud Postgres datasource; first domain dashboards
(wallet/settlement health; instance-state distribution); Synthetics
checks (prod + staging `/health` + DNS, 2–3 regions); CI deploy
annotations.

## SLIs (defined now; SLO targets after the first beta month — ADR-0012 Am. 3)

| Plane | SLI | Definition | Source |
|---|---|---|---|
| Data | Instance availability | ready-to-desired replica ratio across running instances (platform-caused; app crashes excluded) | kube-state-metrics / Instance reconciler state |
| Data | Instance ingress success | non-5xx ratio at the edge for `*.fluxvale.app` | Traefik metrics (enable + Alloy scrape) |
| Control | Web/API availability | non-5xx request ratio, windowed | PromEx |
| Control | Flag-read latency | p95/p99 of the `FeatureFlags.enabled?` lookup (unique-index point read, rides every gated request) — the demand signal [ADR-0023](adr/00023-day-one-gates.md) §2 watches before adding the ETS cache | PromEx (`repo.query` telemetry already emitted; export/alert-only at M4) |
| Control | Auth completion | sign-in success ratio (throttled rejections excluded) | app metric |
| Control | Deploy success rate | instances reaching `running` within N min | domain counter (Instance state machine) |
| Control | Time-to-running | p95 deploy duration | same counter |
| Ops | Metering settlement | `settle_usage` success ratio | Oban metrics |
| Ops | Backup freshness | age of last successful CNPG backup | existing alert |
| Ops | Pipeline health | smoke pass rate (deploy-attached + scheduled) | heartbeat metric |

**Critical user flows** — the SLI catalog is this promise list; the
smoke + E2E suites are projections of the same table. A new critical
flow gets a row, a metric, and a test — one decision, three surfaces:

| Flow | Promise | SLI | Oracle |
|---|---|---|---|
| Sign in | I can get in | auth completion | Playwright login via TestInbox (Bruno proves the API surface with a seeded PAT) |
| Deploy | install just works | deploy success, time-to-running | Playwright lifecycle (staging + review envs) |
| Daily use | it's up, it's fast | instance availability, ingress success | Synthetics edge probe (per-instance synthetics = post-beta idea) |
| Trust the bill | metering is honest | metering settlement | Bruno billing reads + domain dashboard |
| Trust the data | my library survives us | backup freshness | the restore drill |

**Error-budget policy (light)**: >50% of a month's budget burned →
extra deploy scrutiny; gate-on-demand becomes the default.
**Deferred**: burn-rate alerting and public SLOs (traffic /
status-page triggers).

## Alert set (tuned ruthlessly — one noisy alert teaches ignoring all of them)

| Alert | Why |
|---|---|
| 5xx rate / LiveView crash count | deploy went bad |
| Oban failures or queue depth — **deploy, reconciler, metering queues** | billing machinery silently dying is the worst failure class we have |
| Postgres connections near max; disk % | shared-cluster failure modes |
| CNPG replication / backup job age | the launch-gate promise quietly rotting |
| cert-manager cert expiry < 14d | v1 scar |
| Node memory pressure | customer instances evicting |
| Customer instance crash-loop count (cluster-wide) | product incident before a customer emails |
| Smoke or synthetic red (deploy-attached, Bruno correctness, or probe failure from any region) | the oracle spoke |
| Scheduled-run freshness (Bruno heartbeat stale) | dead-man's switch — a silently-stopped cron emits no failure signal |

Routing: email + phone push. Deploy annotations on every dashboard —
with simultaneous deploys, every incident's first question is "what
changed?"
