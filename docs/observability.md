# Observability

Status: Accepted (see [adr/](adr/) — [ADR-00012](adr/00012-observability-grafana-cloud.md), as amended).

## Stack

- **Grafana Alloy agent** in-cluster (~100 MB) shipping to **Grafana Cloud
  free tier** (hosted LGTM). Self-hosting rejected — see ADR-00012's decisive
  argument (blind-when-the-box-dies), cost math, and the lab compromise
  (full LGTM in the local k3d cluster for learning, [ADR-00020](adr/00020-local-dev-parity.md);
  production home someday = the demoted box).
- **Error tracking**: Honeybadger or AppSignal (~$0–20/mo).
- **Synthetic checks**: scheduled Bruno smoke (now) → Grafana Cloud
  synthetic monitoring (later).

## The complete visibility inventory

OTEL + Alloy is the spine; "complete" means these sources and glue too:

| Layer | Source | Notes |
|---|---|---|
| App metrics | **PromEx** (Phoenix/Ecto/Oban/BEAM, prebuilt dashboards) | retained even under OTEL-day-one: Elixir OTEL metrics is weaker than PromEx; OTLP-for-traces-and-logs + Prometheus-for-metrics is the standard split |
| Cluster metrics | cAdvisor (free with kubelet) | per-instance CPU/RAM/disk |
| K8s object metrics | **kube-state-metrics** (deployed via fleet repo) | Alloy scrapes but doesn't generate |
| Node metrics | **node-exporter** (deployed via fleet repo) | disk fill, memory pressure |
| App logs | structured JSON on stdout | Alloy collects + enriches with k8s metadata |
| System logs | Talos kernel/kubelet/etcd | Alloy wiring for Talos host logs |
| Request traces | OTEL SDK (`opentelemetry_phoenix`/`_ecto`) → OTLP → Tempo | |
| **Deploy-pipeline traces** | **custom spans** around Instance deploy/reconcile orchestration | the product's most valuable trace: Oban trigger → namespace → apply → reconcile → running |
| Correlation glue | Logger formatter stamping trace/span IDs into every log line | makes the three pillars one narrative |
| **Domain sight** | Grafana **Postgres datasource** + dashboards over the wallet ledger, settlement runs, instance-state distribution | not telemetry at all — queries on our own DB; for a PaaS operator often the most important dashboard |
| Errors | Honeybadger/AppSignal | exceptions with stack + request context |
| Outside-in | scheduled smoke / synthetics | "is it up from the internet" |

Emission rules: no OTLP log-push from Elixir (immature) — stdout JSON is the
battle-tested path. Customer instances get **metrics only** (no customer log
content ships to the third party — ADR-00012's data rule).

## Day-one checklist

**App (`mix.exs`, first release)**: `opentelemetry`, `opentelemetry_exporter`,
`opentelemetry_phoenix`, `opentelemetry_ecto`, `prom_ex`; Logger formatter
with trace/span IDs; custom span wrappers for Instance deploy + reconcile.

**Fleet repo**: Alloy config (scrape `/metrics` + k8s integrations + OTLP
receiver + Talos host logs); kube-state-metrics + node-exporter charts;
Grafana Cloud Postgres datasource; first domain dashboards (wallet/settlement
health; instance-state distribution); CI deploy annotations.

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
| Smoke suite red (deploy-attached or scheduled) | the oracle spoke |

Routing: email + phone push. Deploy annotations on every dashboard — with
simultaneous deploys, every incident's first question is "what changed?"
