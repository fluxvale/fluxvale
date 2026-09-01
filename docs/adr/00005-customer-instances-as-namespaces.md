# ADR-00005: Customer workloads as k8s namespaces (the Instance model)

**Status**: Accepted (amended — see Amendment 1)
**Date**: 2026-08-27

An **Instance** — an instance *of* a catalog `AppVersion` — is FluxVale's unit
of customer workload: an entire namespace, deliberately *not* a Kubernetes
Pod. The namespace holds the Deployment, Service, IngressRoute, and optional
PVC + Secret that make up one running app.

An Instance runs a state machine
(`pending → deploying → starting → running ⇄ stopped`; `error`;
`deleting` — `running` is the successful, usable state) driven by
AshOban triggers:

- `deploy` — background job creates all K8s resources
- `reconcile_status` — every minute; promotes `starting` → `running`
  when readyReplicas ≥ replicas, demotes on failed rollout conditions
  (`ReplicaFailure`, `ProgressDeadlineExceeded`), and times out stuck deploys
- `settle_usage` — every 15 min; metering settlement
- `teardown` — async delete with retries; hard-deletes the row on success

**Rationale**: the k8s API surface *is* the product — namespaces-as-isolation,
ResourceQuotas, NetworkPolicies, PVCs, readiness semantics, and scale-to-zero
are product features for free. Raw container runtimes or lighter-weight
orchestrators would mean hand-rolling crash-loop detection, resource quotas,
and network isolation — rebuilding Kubernetes badly, and it's the least
differentiated work possible.

**Vocabulary note**: "instance" means exactly this concept across code, docs,
and ops — which is why databases are referred to as "CNPG clusters"
(CloudNativePG's own term; see [ADR-00009](00009-single-cnpg-cluster.md)).

## Amendment 1 (2026-09-01)

Per [ADR-00028](00028-flat-rate-pricing.md): `settle_usage` now accrues the
instance's **flat monthly rate** over elapsed time (running) or the
storage-only flat fee (stopped) — the anchors, advisory locks, and
idempotency machinery are unchanged; only the per-interval computation
simplifies from measured usage to allocation × rate.
