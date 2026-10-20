# ADR-0033: Bring-up data seeds on deploy; missing invariants fail loudly

**Status**: Accepted
**Date**: 2026-10-20

**Context**: Oct 20's first prod dogfood deploy failed silently —
`pricing_sizes` and `clusters` were empty (seeds and `ensure-cluster`
were operator-run commands nobody had run with the current data set),
instance-create validation rejected pre-insert, and the deploy
LiveView rendered nothing: no message, no log, "healthy" the whole
time. Migrations already run per-deploy (advisory-locked init
container); required reference data should not depend on someone
remembering a manual step.

**Decision**:

1. **Deploy = schema + required reference data.** The fleet base
   Deployment gains a `seed` init container after `migrate`: `bin/seed`
   then `bin/ensure-cluster`, with `CLUSTER_NAME` from the container
   env (prod `nuremberg-01`; staging `local`, its existing row). Both
   are idempotent. The cluster row is get-or-create and never
   converges — an admin-set `kubeconfig_ref` is deliberate drift. The
   seed's converge scope is the shipped YAML (prices, tax rates,
   catalog): admin edits to those revert on the next deploy, so edit
   the YAML, not the row. Single-writer among init containers by
   construction — replicas stay 1 and only rolling-in pods run them;
   a manual `bin/seed` re-run must not overlap a rollout (the
   release task's documented single-caller assumption). Revisit
   (advisory-lock the seed, as #173 did for `ensure-cluster`) when
   replicas exceed 1 or overlap can no longer be ruled out.
2. **Flags and access rules stay operator-administered**
   ([ADR-0023](00023-day-one-gates.md) Am. 6,
   [ADR-0030](00030-ops-domain.md)): FeatureFlag and AccessRule rows
   are never seeded.
3. **Readiness owns the invariants.** `/health/ready` fails 503 with
   a `Logger.error` naming each missing invariant — pricing sizes,
   catalog app versions, exactly one cluster row. A half-seeded env
   boots NotReady with a named cause, never "healthy" and broken;
   liveness stays dependency-free (the `/health` contract).
4. **The deploy form shows what the create rejected** — Ash changeset
   errors render on the name step; a field with no input there (the
   Oct 20 shape: `:cluster_id`) no longer vanishes.

**Rejected**: **seeds as migrations** —
[ADR-0013](00013-additive-migrations.md) DDL discipline and seed data
are different lifecycles, and a seed inside a migration can't
re-converge drifted rows. **Self-seeding in the app process at boot**
— a writer inside the serving process races admin edits and boot
order; init containers already serialize before traffic. **Crash
instead of readiness-fail** — a crash-looping pod hides the cause;
NotReady plus a named log line points straight at it. **Manual-only
bring-up (the status quo)** — Oct 20. **Seeding flags/AccessRules** —
settled empty-then-close on #26.
