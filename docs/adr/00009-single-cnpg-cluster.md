# ADR-00009: One shared CNPG cluster; managed PostgreSQL is the scaling path

**Status**: Accepted
**Date**: 2026-08-27

*Terminology: CloudNativePG's own term for a managed Postgres is "cluster"
(its CRD is `Cluster`), so we say **CNPG cluster** — keeping "instance"
reserved for customer workloads ([ADR-00005](00005-customer-instances-as-namespaces.md)).*

**Context**: two clusters (prod-dedicated + shared utility) was the initial
position, motivated by blast-radius isolation: PITR granularity is
cluster-wide (restoring one database rolls back every cotenant's writes),
staging's job is risky rehearsals, and a prod-only cluster makes restore
drills honest. Reconsidered against the actual strategy: minimize cost while
pre-profit, cram everything onto one bare-metal box. Under that strategy,
**anything still on the box is by definition pre-traction** — the moment a
product has real users it moves to managed PostgreSQL — and pre-traction
data is low-stakes and WAL-G-protected. ~1 GB of RAM for isolation insurance
on data that is, by construction, not yet worth much was judged too
cautious.

**Decision**: **one shared CNPG cluster** on the box:

- Separate **database per tenant** — platform prod, platform staging, each
  first-party product. Never shared schemas (weaker boundary).
- CNPG's charter: a **realistic Postgres to build and beta against**, with an
  easy managed-PG upgrade path (dump/restore + `DATABASE_URL` swap). It is
  not meant to serve scaled traffic.
- **Extensions are per-database, not per-cluster**: usage via
  `CREATE EXTENSION` in the tenant's DB; availability via image composition
  (CNPG's official extension images incl. pgvector + ImageVolume). A cluster
  split is warranted only for cluster-level extension impacts
  (`shared_preload_libraries` conflicts, background-worker extensions,
  version pinning).

**Guardrails that make this sound**:

1. **Traction-onset migration trigger** — the moment a product gets real
   revenue or sustained usage, its database moves to managed PostgreSQL
   (same region). Move it when it starts working, not when it starts
   hurting; rehearse the move early. The dangerous window is
   traction-without-migration.
2. **Postgres-level rehearsals and restore drills run on a temporary
   scratch CNPG cluster** — spun up for the drill, torn down after (RAM only
   during drills). Version-upgrade rehearsals and backup-restore drills
   never execute inside the shared envelope. Day-to-day staging lives on the
   shared cluster as a normal tenant database.
3. **Per-tenant mitigations** (the practical blast-radius shrinkers):
   per-tenant roles with `CONNECTION LIMIT`, `REVOKE CONNECT ... FROM
   PUBLIC` per database, PgBouncer with per-database pools, per-database
   size monitoring, batched backfills only ([ADR-00013](00013-additive-migrations.md)).
4. **WAL-G → R2 backups from day one**; scheduled scratch-cluster restore
   drills (the launch-gate drill).

**Blast radius accepted**: the shared envelope (connections, shared_buffers,
autovacuum workers, disk + WAL stream, failover blips, cluster-wide upgrades,
cluster-granular PITR) couples all tenants — including the billing ledger
with staging's day-to-day work. Accepted because every cotenant is
first-party and pre-traction.

**RAM**: ~1–1.5 GB vs ~2–3 GB for two clusters.

**Rejected — two clusters (prod dedicated + utility)**: revisit when a
product earns the traction migration but self-hosted isolation is preferred
over managed PG, or if a traction migration stalls and the ledger's stakes
make cotenant rollback unacceptable. Blast-radius details and mitigations
above carry over unchanged.
