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

## Amendment 2 (2026-10-22)

The Oct-21 incident (fluxvale/fluxvale#196): a running staging instance's
namespace was deleted by **our own production orphan sweep** — staging and
production share one physical cluster (ADR-0010 same-box), each with a
Cluster row, and the stranded-instance sweep deleted any instance-shaped
namespace with no row in *its own* DB. Three changes, all settled on #196:

- **Env-scoped namespaces**: deploy stamps every instance namespace with
  `fluxvale.io/platform-env` (config `:platform_env`, fleet sets
  `PLATFORM_ENV`); the orphan sweep deletes only namespaces carrying its
  own value. Foreign-env and unlabeled namespaces are never the sweep's
  to touch.
- **`lost` state**: reconciliation now detects a namespace that vanished
  under a live row and flips it to `:lost` instead of accruing forever —
  the per-minute reconciler covers `:starting`/`:running`, the hourly
  sweep backstops accruing `:running`/`:stopped`/`:error` rows
  (never-ran `:error` rows accrue nothing and stay retryable). Metering
  anchors park atomically with the flip (billing stops at detection),
  and the owner re-deploys or tears down from the UI. `lost` enters from
  the deployed states; its exits are re-deploy (`:deploying`) and
  teardown.
- **The reconciler's 403 blind spot**: the platform SA's deployment reads
  ride the per-namespace RoleBinding, which dies with the namespace — so a
  deleted namespace answers Deployment GETs with **403, not 404**, and the
  `:not_found`-only match silently no-op'd for 90+ minutes. Both 403 and
  404 now double-check the namespace (the SA's cluster-scoped namespace
  read sees through a dead namespace), and every reconcile *failure* arm
  logs — a detector that fails quietly is indistinguishable from one that
  affirmed health.

## Amendment 3 (2026-10-22)

Per [ADR-0036](00036-scale-to-zero-wake-on-use.md) (#203): the state
machine gains **`sleeping`** — the idle loop's own leg. `running →
sleeping` is the platform's idle sweep (scale-to-zero, edge routes
re-pointed at the wake endpoint); `sleeping → starting` is the wake
(any visitor, or the owner's Wake button — the start lane, the
reconciler still the only writer of `:running`). Metering-wise sleeping
is stopped: leaving `:running` folds the running interval and the
storage anchor keeps accruing storage-only. Stop stays the owner's
verb; sleep is the platform's, and traffic reverses it.
