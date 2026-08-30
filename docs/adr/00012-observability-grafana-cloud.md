# ADR-00012: Observability via Alloy → Grafana Cloud free tier

**Status**: Accepted
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
