# ADR-00012: Observability via Alloy → Grafana Cloud free tier

**Status**: Accepted (amended — see Amendments 1–2)
**Date**: 2026-08-27

**Decision**: a Grafana Alloy agent in-cluster (~100 MB) ships metrics, logs,
traces to Grafana Cloud's **free tier** (hosted LGTM: ~10k series, 50 GB logs,
50 GB traces — years of headroom at beta scale). PromEx for Elixir metrics
day one (Phoenix/Ecto/Oban/BEAM with pre-built dashboards); Honeybadger or
AppSignal for error tracking; OTEL traces (`opentelemetry_phoenix`/`_ecto`)
once metrics+logs are boring.

**Rationale**: self-hosted LGTM costs ~3 GB RAM plus an operator's worth of
upkeep — contradicting the resource discipline that freed exactly that RAM
(Authentik, Reflector, the SPA). v1's own architecture doc had already
concluded this (Alloy → Grafana Cloud Free). The OTEL-native agent keeps the
vendor swappable: repoint the endpoint to self-hosted later.

**The decisive argument** (stronger than RAM): an observatory on the observed
box is blind exactly when it matters — when the box dies, same-box monitoring
dies with it, including alert evaluation. Cloud-hosted alerting pages you
*from their infrastructure* when the box is unreachable; self-hosted would
need an external dead-man's-switch anyway. Cost math also favors cloud under
the cost-minimization strategy: €0 vs ~2.5–3 GB of the box's only billable
capacity (customer-instance headroom), with retention competing with customer
PVCs for the same NVMe. Headroom check: the binding limit is ~10k series;
platform (~1–2k) + node (~1k) + ~20 series per instance ≈ 4–5k at 100
instances — years of room. **Data rule**: platform metrics/logs and
customer-instance **metrics** only; no customer log content ships to the
third party.

**Self-hosting as a learning goal**: the lab is the local dev cluster
([ADR-00020](00020-local-dev-parity.md)) — full LGTM (Prometheus, not Mimir) in k3d at zero production
cost, with the lightweight `grafana/lgtm` all-in-one container as an
on-ramp. Usage fluency (UI, PromQL/LogQL/TraceQL, dashboards, alerts)
transfers identically from cloud; ops depth (upgrades, retention, storage)
comes from the lab. Production self-hosting lands naturally later: the
**demoted box** after vertical scaling ([ADR-00006](00006-single-cluster-multi-region-ready.md)) is its intended home when
paying-customer-free RAM exists.

**Instrumentation boundary**: the platform app gets full instrumentation;
customer instances get kubelet/cAdvisor metrics via Alloy — OTEL for customer apps
is not ours to provide.

**Revisit trigger**: outgrowing the free tier (see [ADR-00016](00016-deferred-triggers.md)). Self-hosting
then is a "revenue justifies it" item, same tier as the second server.
Details: [../observability.md](../observability.md).

## Amendment 1 (2026-09-01)

**OTEL moves to day one** (was: "traces once metrics+logs are boring").
`opentelemetry_phoenix`/`_ecto` + OTLP export ship with the first release,
plus custom spans around the Instance deploy/reconcile orchestration (the
product's most valuable trace) and a Logger formatter stamping
trace/span IDs into every log line for pillar correlation.

**OTEL + Alloy is the spine, not the whole skeleton** — "complete"
visibility additionally requires: kube-state-metrics and node-exporter
(Alloy scrapes but does not generate them), Talos system-log wiring,
PromEx retained for metrics (Elixir-idiomatic, prebuilt dashboards;
OTLP-for-traces-and-logs + Prometheus-for-metrics is the standard split),
error tracking (Honeybadger/AppSignal), and **domain sight** — Grafana's
Postgres datasource querying the wallet ledger and instance states,
which no telemetry pipeline provides. Full inventory:
[../observability.md](../observability.md).

## Amendment 2 (2026-09-01)

**Error tracking goes Grafana-first; the dedicated tracker is deferred.**
Day-one error visibility rides the existing stack: exceptions with
stacktraces land in Loki via structured ERROR logs (the Logger JSON
formatter includes exception module/message/stacktrace + user/trace IDs;
Oban failures log at ERROR by default), OTEL records exception events on
Tempo spans automatically, and LogQL queries + derived-field links form
the triage surface — an `error_signature` label derived from the exception
module, never the full message (label-cardinality discipline). What a
dedicated tool uniquely provides — the issue inbox: auto-grouping,
resolved state, regression flags — earns its subscription at error
*volume*, not at solo scale. Trigger added to
[ADR-00016](00016-deferred-triggers.md): triage becomes a workflow (beta
users, regression tracking) → add Honeybadger or AppSignal.
