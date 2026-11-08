# ADR-0045: Bundled per-instance backing services (Postgres, Redis in the instance pod)

**Status**: Accepted
**Date**: 2026-11-08

**Context**: catalog-class apps overwhelmingly want a database and a
cache (Docmost needs Postgres + Redis, Vikunja wants Postgres, Umami
needs Postgres). Today the only platform answer is BYO inputs — the
user brings a `DATABASE_URL` from somewhere else, or the app runs on
SQLite on the instance PVC. The waiting consumer entries (#609, #610,
#587) make the gap load-bearing. The shared CNPG cluster
([ADR-0009](00009-single-cnpg-cluster.md)) is first-party-only by
design, and OQ #14's unsettled clause ("instances get
platform-provisioned DBs") priced that as an ADR-0009 amendment — a
provisioning layer, blast-radius coupling, billing-ledger entanglement.
PikaPods is the prior art worth stealing: each app pod bundles its own
Postgres, env-wired, pod-scoped resources, data on the app's volume.

**Decision**: AppVersions may declare bundled backing services
(today Postgres and Redis, one of each at most) as validated catalog
metadata; at deploy the platform renders them as containers **inside
the instance's own pod** — native sidecar init containers with startup
probes (`pg_isready`, `redis-cli ping`), so the app container cannot
start until both accept connections. Data lands on the instance's
existing `app-data` PVC under `backing/` subPaths. Credentials are
generated once into a get-or-create K8s Secret (never rotated — the
PG password hash lives in the data dir). The platform composes each
declared `url_env` (`DATABASE_URL`, `REDIS_URL`) at deploy, above user
values. Resources are carved **from the purchased allocation** (D1:
PG 0.10 CPU / 256 MB, Redis 0.05 / 64 MB), so quota math, stop/start/
sleep/wake, and the reconciler's readiness contract are untouched.
No new Services, no NetworkPolicy change — same-pod reachability is
`localhost`.

Settled decisions ([plan](../plans/612-backing-services.md) §9, all
as recommended, Terence Nov 8 2026):

- **Image governance (D2)**: the platform registry
  (`config :flux_vale, :backing_services`) owns exact image pins;
  entries declare majors; instances snapshot the resolved ref at
  create. A registry bump can never shift a live instance's DB
  version under it — not on redeploy, not on resize.
- **Takeover semantics (D6)**: when a backing service owns a key, a
  user value naming it is **rejected loudly at instance create** with
  an honest error — a tested behavior, never a log line. The wizard
  never renders the input. Pinned instances are never retconned;
  migrating a live entry (Umami's future move, OQ #3) is a deliberate
  per-instance op — new version row + owner-chosen move.
- **Honest sizing (D4, D5)**: DB-backed entries ship bigger defaults,
  and the below-recommendation path **refuses** for them — compute
  and storage floors at the version defaults. Refuse, don't sell
  broken: under-sizing starves the DB, and the DB's failure mode is
  the app's data integrity.
- **Redis auth (D7)**: generated `requirepass`; the URL carries it.
- **Readiness (D8)**: native sidecars with startup probes (cluster
  floor k8s ≥ 1.29; local k3d probed v1.37). Explicit wait-init
  containers are the named fallback if probe semantics prove subtle
  in practice.

**What it settles**:

- **OQ #14's per-instance clause — by avoidance.** Instances DO get
  databases; none of the ADR-0009 amendment's cost is paid (no
  cluster involvement, no provisioning layer). The managed-DB
  **product** shapes (DB-as-catalog-app, `fluxvale db`) stay deferred
  with their triggers
  ([open-questions.md](../open-questions.md) #14).
- **OQ #3's takeover trigger gets its semantics** — recorded here,
  activation deferred: Umami's BYO→bundled migration (#587) is
  Terence's later lane and reuses exactly the D6 stance above.
- **[ADR-0009](00009-single-cnpg-cluster.md) is untouched** — the
  shared cluster keeps its first-party cotenants; customer app
  databases never touch it. No amendment.

**Rejected alternatives**:

- **Per-tenant databases in the shared CNPG cluster** — needs the
  ADR-0009 amendment (customer DBs in a first-party envelope), couples
  customer blast radius to the billing ledger, and buys nothing at
  single-node scale. Stays the managed-DB product's question (OQ #14,
  deferred).
- **A separate Deployment/StatefulSet per service** — cross-pod
  readiness ordering, separate quota accounting, Services +
  NetworkPolicy entries, and stop/start paths that must coordinate
  multiple objects; complexity for zero isolation gain (same
  namespace, same node, same volume either way).
- **Managed DBaaS** — cost and region coupling; the traction-onset
  migration trigger ([ADR-0009](00009-single-cnpg-cluster.md)
  guardrail 1) already names that escape hatch for apps that outgrow
  the bundled model.
- **Resources as platform overhead on top** (the file-access stance,
  [ADR-0035](00035-per-instance-file-access.md)) — rejected for
  honesty: the file-access sidecar is plumbing the user didn't buy; a
  database is half the workload the user IS buying. Bigger defaults
  and plain-copy disclosure ("includes PostgreSQL 18 and Redis 8")
  follow.

**Posture statements** (recorded, not new):

- **Backups stay user-owned** (BYO S3,
  [ADR-0037](00037-instance-backups-s3.md) — un-quiesced PVC copies,
  a caveat scoped when it settled to the SQLite/git apps). For a
  bundled DB the honest owner tools are a **stopped-instance** backup
  or a logical dump (`pg_dump`): a file-level copy of a *running*
  Postgres data dir is not guaranteed restorable, so the backup
  surface's plain-words caveat must name DB-backed entries (S3).
  A PG-native backup integration is the recorded later trigger.
- **Destroy = data gone** — the existing teardown posture, unchanged;
  the DB data rides the instance PVC.
- **In-place DB major upgrades are deferred** with their trigger: the
  snapshot pins each instance's DB image, a newer version row may
  declare a newer major, and moving a live instance across majors is
  a future deliberate op (new instance + data import, or an
  in-place-upgrade lane if demand appears).
