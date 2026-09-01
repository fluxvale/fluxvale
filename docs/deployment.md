# Deployment

Status: Accepted (see [adr/](adr/) — ADRs [00011](adr/00011-simultaneous-deploy-post-deploy-smoke.md), [00013](adr/00013-additive-migrations.md)–[00015](adr/00015-no-auto-remediation.md)).

## Pipeline

```text
merge to main (app repo)
   │
   ▼
CI job 1: build OTP release → image → push ghcr.io/fluxvale/fluxvale:sha-<sha>
   │
   ▼
Flux image automation (fleet repo): bumps staging AND prod manifests (1–5 min)
   │
   ▼
Rolling update: init container runs migrations (advisory-locked) → readiness
probe (health + DB check) gates traffic → old pods drain
   │
   ▼
CI job 2: watch-deploy — poll https://staging.fluxvale.com/health and
https://fluxvale.com/health until version == sha-<sha> in BOTH environments
(the prod suite must not run against the old image — Flux can reconcile the
envs at different times)  (verifies the whole
chain: DNS → Cloudflare → Traefik → pod; zero cluster credentials in CI)
   │
   ▼
CI job 3: smoke
   ├─ staging: Bruno suite + FULL Playwright (destructive allowed)
   └─ prod:    Bruno suite + read-only Playwright subset (no side effects)
   │
   ▼
green → Grafana deploy annotation, done
red  → alert (phone push) + auto-opened revert PR + PR comment + annotation
```

Merge-to-verified ≈ 12–20 minutes. Readiness probes already self-contain
boot-broken deploys (new pod never goes ready → old pods keep serving); the
smoke layer catches boots-fine-but-misbehaves.

The app exposes `GET /health` → `{status, version}` where `version` is the
build SHA, and the readiness probe checks health + DB connectivity.

### Scheduled monitoring (two layers)

1. **Availability — Grafana Synthetics** (day one; part of the Cloud free
   tier): `/health` HTTP checks + a DNS check on prod and staging, from 2–3
   probe regions at minutes-level cadence. Multi-region vantage catches
   Cloudflare/DNS/cert reachability problems a single CI runner cannot see;
   alerts fire through the same Grafana alert pipeline as everything else.
2. **Correctness — scheduled Bruno** (30–60 min cron): the deep,
   authenticated business flows against both envs — the same collection
   that gates deploys, changed in the same PR as the API. GitHub's cron is
   best-effort, which is fine now that availability is Synthetics' job.
   Failures push a metric via Grafana remote-write so their alert rides the
   unified pipeline too. **Heartbeat**: every run — passing or failing —
   pushes a run-success timestamp metric; a dead-man's-switch alert fires on
   staleness, because a silently-stopped cron produces no failure signal at
   all.

## Feature flags

Divergence between staging and prod is feature flags only — a `FeatureFlag`
Ash resource (key, enabled, optional rollout %) with a tiny LiveView admin
page, separate values per environment via separate databases. Flags gate
*features*, never schema. Delete flags on a schedule.

## Migration rules (load-bearing)

Simultaneous deploy means code+schema land everywhere at once, but rolling
windows and rollbacks still require additive-only discipline:

1. A release ships **only additive** migrations; destructive changes ride a
   later "contract" release.
2. Review every generated migration — `DROP`, `ALTER`, new `NOT NULL` lines
   demand scrutiny. (Ash codegen renders renames/removals as drops.)
3. Backfills are batched release tasks or background jobs, never inline
   migrations.
4. New enum states and new Oban arg shapes wait a full deploy cycle before
   anything writes them.
5. `CREATE INDEX CONCURRENTLY` for indexes on real tables (with
   `@disable_migration_lock`).

One-way doors (prevention only — this is what gate-on-demand is for):
overwriting backfills, column type changes losing data, dropped columns with
data, **Postgres enum value removal** (unsupported — requires type recreation),
destructive rewrites.

### Gate-on-demand

Default is simultaneous deploy. For a scary migration (table rewrite, risky
constraint), pin prod in the fleet repo (one line), let staging run it, prove
it, release. Opt-in gate, not a standing one.

## Rollback protocol

**Rollback = roll forward through the same pipeline.** Never `kubectl rollout
undo` (Flux reasserts git state within minutes), never `ecto.rollback` outside
dev, never delete an applied migration file.

| Failure | Response |
|---|---|
| Broken deploy, no migration | Revert the app PR → new image → Flux rolls both envs. Done. |
| Additive migration, feature broke | **Revert code only; leave schema — but only if the schema remains write-compatible with the previous image** (nullable additions yes; new `NOT NULL`/constraints the old code can't satisfy → harmful-migration row). Orphaned additive schema is harmless; clean up in a later contract release. This is the default — counter-migrations are rare (ADR-00014 Am. 1). |
| Harmful migration itself | Revert PR = code revert **+ counter-migration** (new migration N+1). Generate it by reverting the resource code and letting the Ash migration generator diff the undo, then review. One deploy, code and schema revert in lockstep. |
| One-way door | Fix forward or restore from backup. |

Manifest-caused failures (bad limits, Traefik config): revert the **fleet
repo** PR instead — same protocol, different repo.

## On failure: automate detection and preparation, keep the decision human

On smoke failure, automation **alerts** (phone push, deep-linked),
**opens the revert PR** (`gh pr revert <n>`), comments on the offending PR,
and posts a Grafana annotation. A human merges (one tap from the phone) or
writes the proper counter-migration PR. No auto-merge.

Upgrade path to full auto-revert (only if the smoke suite proves weeks of
near-zero flakiness AND deploys start happening while AFK): auto-merge the
prepared revert **only when the offending diff contains no files under
`priv/repo/migrations`** — migration-touching failures always escalate to a
human.
