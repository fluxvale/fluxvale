# Observability

Status: Accepted (see [adr/](adr/) — [ADR-00012](adr/00012-observability-grafana-cloud.md)).

## Stack

- **Grafana Alloy agent** on the box (in-cluster) shipping metrics, logs,
  traces to **Grafana Cloud free tier** (hosted LGTM: ~10k series, 50 GB logs,
  50 GB traces — years of headroom at beta scale). Self-hosted LGTM rejected:
  ~3–4 GB RAM for the stack + 2am ops = contradicts the resource discipline.
- **PromEx** for Elixir metrics — Phoenix, Ecto, Oban, BEAM, with pre-built
  Grafana dashboards. Day-one item.
- **Error tracking**: Honeybadger or AppSignal (~$0–20/mo). Traces say *where*
  it broke; error tracking gives the exception + stack + request context.
- **Traces later**: `opentelemetry_phoenix` / `opentelemetry_ecto` once metrics
  + logs are boring. Least valuable leg at beta traffic.
- Self-hosting the LGTM stack is a "revenue justifies it" item (same tier as
  the second server). The Alloy/OTEL endpoint keeps the vendor swappable.

## What's instrumented vs not

- The **platform app** gets full instrumentation (PromEx + logs + errors).
- **Customer instances** get kubelet/cAdvisor metrics via Alloy — per-instance CPU/RAM/
  storage. OTEL for customer apps is not ours to provide.

## Deploy annotations are the killer feature

With simultaneous deploys, every incident's first question is "what changed?"
CI writes a Grafana annotation at every rollout (and on smoke failure /
revert), on every dashboard. "deploy → smoke red → revert" reads as one
narrative.

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

Routing: email + phone push. Scheduled smoke (every 15–30 min) doubles as
synthetic monitoring for non-deploy breakage.
