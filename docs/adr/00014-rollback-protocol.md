# ADR-00014: Rollback protocol — revert PRs, counter-migrations, never raw rollback

**Status**: Accepted (amended — see Amendment 1)
**Date**: 2026-08-27

**Principles**: rollback = **roll forward through the same pipeline** — a
revert PR produces a new image, Flux deploys it, the same smoke verification
applies. Migrations run in init containers (advisory-locked) so the image is
the single unit carrying code+schema version. Never `kubectl rollout undo`
(Flux reasserts git state within minutes), never `ecto.rollback` outside dev,
never delete an applied migration file (Ecto's `schema_migrations` would drift
across environments).

**Decision tree**:

| Failure | Response |
|---|---|
| Broken deploy, no migration | Revert the app PR → new image → Flux rolls both envs. |
| Additive migration, feature broke | **Revert code only; leave schema — but only if the schema remains write-compatible with the previous image** (nullable columns yes; anything the old code must populate — new `NOT NULL`, constraints, rewritten defaults — no: that is the harmful-migration row). Orphaned additive schema is harmless; clean up in a later contract release. *This is the default — counter-migrations are rare.* |
| Harmful migration itself | Revert PR = code revert **+ counter-migration** (new migration N+1). Generate it by reverting the resource code and letting the Ash migration generator diff the undo, then review the drops. One deploy, code and schema revert in lockstep. |
| One-way door | Fix forward or restore from backup. |

Manifest-caused failures (bad limits, Traefik config): revert the **fleet
repo** PR instead — same protocol, different repo.

Full detail: [../deployment.md](../deployment.md).
