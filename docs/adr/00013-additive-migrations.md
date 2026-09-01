# ADR-00013: Migration discipline — additive-only per release

**Status**: Accepted
**Date**: 2026-08-27

Even with simultaneous deploys ([ADR-00011](00011-simultaneous-deploy-post-deploy-smoke.md)), rolling windows (old pods on new
schema during rollout) and rollbacks ([ADR-00014](00014-rollback-protocol.md)) mean old code can always meet
new schema. Additive-only keeps every such window a non-event. Simultaneous
deploy keeps the discipline *cheap* ("review the diff") rather than
load-bearing — but it never drops to zero.

**The five rules**:

1. A release ships **only additive** migrations; destructive changes ride a
   later "contract" release.
2. Review every generated migration — `DROP`, `ALTER`, and new `NOT NULL`
   lines demand scrutiny. (Ash codegen renders renames/removals as drops.)
3. Backfills are batched release tasks or background jobs, never inline
   migrations.
4. New enum states and new Oban arg shapes wait a full deploy cycle before
   anything writes them.
5. `CREATE INDEX CONCURRENTLY` for indexes on real tables (with
   `@disable_migration_lock`) — a small staging DB passes the gate while a
   fat prod table locks for minutes; data volume is the smoke oracle's blind
   spot.

**One-way doors** (prevention only — this is what gate-on-demand exists for):
overwriting backfills · column type changes losing data · dropped columns
with data · **Postgres enum value removal (unsupported — requires type
recreation)** · destructive rewrites.
