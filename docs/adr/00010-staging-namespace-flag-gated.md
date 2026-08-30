# ADR-00010: Staging = same-box namespace, feature-flag gated

**Status**: Accepted
**Date**: 2026-08-27

**Context**: staging "should be its own environment," but a dedicated box
(~€10/mo) isn't worth buying yet. v1 ran staging as namespaces on the prod box
— expensive only because the control plane was an in-cluster workload, which
meant a second full platform deployment.

**Decision**: staging is a second Deployment in `fluxvale-staging` (tight
ResourceQuota) against the staging database on the shared CNPG cluster.
Same image as prod, deployed
simultaneously ([ADR-00011](00011-simultaneous-deploy-post-deploy-smoke.md)); **feature flags gate exposure** — a `FeatureFlag`
Ash resource (key, enabled, optional rollout %) with values diverging
naturally via separate databases. Flags gate *features*, never schema; flags
get deleted on a schedule.

**Staging's roles**: flag-gated exposure · stateful test sandbox (the safe
place for the full/destructive Playwright suite) · upgrade + restore drill
target.

**Separation discipline (structural, not conventional)**: distinct DBs,
distinct secrets, distinct Traefik routes; staging DB excluded from backups —
its job is disposability. Customer instances share the node with staging
workloads; ResourceQuota on staging namespaces is the mitigation, accepted at
beta scale.

**Upgrade path**: when €10/mo feels right, the split is a config change —
env-driven setup points at the new box's k3s and Postgres.
