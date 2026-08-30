# ADR-00016: Named revisit triggers for deferred items

**Status**: Accepted
**Date**: 2026-08-27

Deferred ≠ forgotten. Each deferred item has an explicit trigger:

| Item | Revisit when |
|---|---|
| Second Netcup node (capacity/redundancy) | prod box pressure or single-node anxiety; triggers the Longhorn-vs-node-pinning storage decision |
| Control-plane HA (3 k3s server nodes) | the control-plane SPOF starts costing real incidents |
| Dedicated staging box (~€10/mo) | revenue makes it trivial; split is a config change by design |
| Flagger canary + traffic splitting | traffic volume makes 5% statistically meaningful (needs the metrics stack) |
| Self-hosted LGTM | genuinely outgrowing Grafana Cloud free tier |
| Managed Kubernetes (any region) | a concrete need appears; slots in as a `Cluster` row |
| First traction signal on a product (paying users / sustained usage) | migrate that product's DB to managed PostgreSQL ([ADR-00009](00009-single-cnpg-cluster.md)) — never a second self-hosted cluster. (FluxVale itself scales by bigger box, [ADR-00006](00006-single-cluster-multi-region-ready.md) — its DB stays CNPG) |
| FluxVale gains traction | bigger Netcup box: migrate platform + customer instances (new cluster + WAL-G restore + `Cluster` repoint), demote the current box to projects/experiments ([ADR-00006](00006-single-cluster-multi-region-ready.md)) |
| PocketID managed SSO for catalog apps | post-beta product feature (v1 #356) — decoupled from platform auth since [ADR-00003](00003-ashauthentication-drop-authentik.md) |
| First-party products on the platform | own repos, after the v2 launch gate (open question #2) |
| Re-evaluating [ADR-00008](00008-app-runs-in-cluster.md) placement | building HA Postgres / node #2 era |

Items move off this list via an ADR amendment or a new ADR, never by silently
drifting.
