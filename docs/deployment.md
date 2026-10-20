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
Rolling update: init containers run migrations (advisory-locked) then
bring-up seeds + the cluster row (`bin/seed`, `bin/ensure-cluster` —
[ADR-0033](adr/00033-auto-seed-on-deploy.md)) → readiness
probe (health + DB + boot invariants) gates traffic → old pods drain
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
    ├─ staging: Bruno suite + full Playwright — lifecycle included
    │  since staging went instance-capable (Cluster row + wildcard
    │  cert, #116)
    └─ prod:    Bruno suite + read-only Playwright subset (no side effects)
    │
    ▼
green → Grafana deploy annotation, done
red  → alert (email — routing is email-only for now, phone push
        deferred per observability.md; the failing run's URL rides the
        red check, PR comment, and annotation) + auto-opened revert PR
        + PR comment + annotation. The revert PR's CI is dispatched
        onto its branch — PRs opened by CI's own token fire no events.
```

Merge-to-verified ≈ 15–35 minutes — job 3's staging lifecycle
dominates (cold Forgejo pulls and a retry push past it). Readiness
probes self-contain
boot-broken deploys (new pod never goes ready → old pods keep
serving); smoke catches boots-fine-but-misbehaves.

Health routes (issue #4): `GET /health` → `{status, version}`, version
= build SHA — liveness, deliberately dependency-free (a liveness
failure restarts the pod). `GET /health/ready` — readiness: health +
DB connectivity + boot invariants (#175), 503 `unhealthy` on failure;
the probe that gates traffic.

### Oracle auth: PAT for Bruno, TestInbox for Playwright

Human flows (email-code login) live on the LiveView channel, not
public HTTP — only the deliberate machine surface
([ADR-0019](adr/00019-machine-first-api-cli-mcp.md)) exposes
endpoints. So the oracles authenticate differently:

- **Bruno** (`apps/smoke/`): pre-provisioned smoke PAT per env — minted
  at bring-up through the code interface (release rpc, operator path;
  neither the promotable seed nor AshAdmin — see #99), GitHub secret,
  rotated on its 1-yr schedule (re-mint, update the secret, revoke the
  old) — proves PAT validation and policies on authed reads; no inbox
  dependency, no rate-limit interplay; cheap HTTP at the 30–60 min
  cadence. One PAT per env: each env has its own signing secret and
  token store, so no single token validates on both.
- **Playwright** owns the human flows: drives the real login form,
  fetches the code via the **TestInbox helper** (Swoosh-local JSON
  endpoint on staging/local/review envs — admin-gated; Postmark
  Messages API on prod), submits, observes logged-in state. The
  email-code flow is exercised on every deploy — exactly when it
  changes. The smoke account needs a throttle exemption/dedicated
  bucket on the send-code endpoint so post-deploy + scheduled passes
  don't trip their own rate limit.
- **CLI login follows the PAT model** (gh-style): create a PAT in the
  web UI, paste into the CLI — no email-code-over-API endpoints.

### Break-glass sign-in (`bin/owner-signin`, #165)

Prod cannot deliver mail yet (`Swoosh.Adapters.Local`), so a requested
code dies in the pod's memory and no human can sign in on fluxvale.com.
Until a prod mailer lands, the operator prints one code on their own
terminal:

```sh
kubectl exec -n <namespace> deploy/fluxvale-platform -c platform -- /app/bin/owner-signin
```

The gate is `OWNER_EMAIL` when set, else the environment's **single
platform admin** (zero or several raises — set `OWNER_EMAIL`). Nothing
else can request a code: no route, nothing seeded, no argv. The code
expires in 10 minutes, one send per address per 60 seconds, and the task
prints it to stdout — never to the pod log. It runs through
`eval` (no supervision tree, so the AccessRule cache is read
straight-through); the AccessRule gate itself still applies.

### Scheduled monitoring (two layers)

1. **Availability — Grafana Synthetics** (day one, Cloud free tier):
   `/health` + DNS checks on prod and staging, 2–3 probe regions,
   minutes-level cadence. Multi-region vantage catches
   Cloudflare/DNS/cert problems a single CI runner can't; alerts ride
   the same Grafana pipeline.
2. **Correctness — scheduled Bruno** (30 min cron,
   `smoke.yml`): deep, authenticated business flows against both envs —
   the same collection that gates deploys, changed in the same PR as
   the API. GitHub's cron being best-effort is fine now that
   availability is Synthetics' job. Failures post a Grafana annotation
   carrying the run URL and write **no heartbeat**.
   **Heartbeat**: on full success — and only then — the run
   remote-writes `fluxvale_smoke_heartbeat_count` to the hosted Prom
   (value = run number). Absence is the failure signal: a dead-man's
   switch alert (`absent_over_time`, 45m window — tolerates the cron's
   best-effort jitter at 30-min cadence, one fully-missed run pages)
   fires on staleness. Scheduled failures ride that page — no revert
   PR, there's no deploy to blame (a scheduled failure with nothing
   deployed is an environment problem, not a code one).

## Bring-up: Cluster row + instance slugs

An instance create needs **exactly one** Cluster row (`ResolveCluster`
refuses zero or many). The row is created on every deploy by the
`seed` init container's `bin/ensure-cluster` step, named by the env's
`CLUSTER_NAME` (prod `nuremberg-01`, staging `local`;
[ADR-0033](adr/00033-auto-seed-on-deploy.md)) — get-or-create, never
converge: an admin-set `kubeconfig_ref` is deliberate drift the task
must not revert. A re-run under a different name raises instead of
adding a second row. Post-bring-up CRUD stays AshAdmin
([ADR-0027](adr/00027-admin-surface-ashadmin.md)); the operator path
still exists for manual re-runs:

```sh
kubectl exec -n <namespace> deploy/fluxvale-platform -c platform -- \
  env CLUSTER_NAME=nuremberg-01 /app/bin/ensure-cluster
```

`kubeconfig_ref` stays NULL — the in-cluster service-account sentinel
([ADR-0006](adr/00006-single-cluster-multi-region-ready.md) Am. 2). The
task is get-or-create and never converges: an admin-set ref is
deliberate drift it must not revert.

Instance slugs (`<slug>.fluxvale.app`) are unique per cluster only, and
the deployed envs share the `*.fluxvale.app` wildcard — one cert, one
TLSStore — so the DB can't prevent a cross-env label collision. The
policy is an env-scoped prefix: prod (no `INSTANCES_SLUG_PREFIX`) mints
bare `adjective-noun-####` labels; staging sets `INSTANCES_SLUG_PREFIX=stg`
(labels `stg-<slug>`) and can never take a prod label.

## Bring-up seeds

`bin/seed` runs on every deploy (the fleet's `seed` init container,
after `migrate` — [ADR-0033](adr/00033-auto-seed-on-deploy.md); dev
`mix setup` and a manual `kubectl exec … bin/seed` run the same
`FluxVale.Seeds.seed/0`) and converges bring-up data: platform admin
(+ its personal org), prices, tax rates, catalog. Idempotent — a
re-run changes nothing except reverting admin edits to the shipped
YAML rows (edit the YAML, not the row).

Readiness backstops the seed: `/health/ready` fails 503 with an error
log naming any missing invariant (pricing, catalog, exactly one
cluster) — a half-seeded env never serves traffic "healthy".

The seed also heals the bootstrap admin's missing personal org: org
provisioning (#119) rides the User `create` action, so accounts created
before it have no org and can neither deploy nor top up. Any **other**
legacy account is an operator remedy, never seed data (same posture as
other operator-entered rows): heal it through the release rpc —

```sh
/app/bin/flux_vale eval 'FluxVale.Accounts.provision_personal_org(FluxVale.Identity.User.get_by_email!("user@example.com", authorize?: false))'
```

Idempotent — a second call adds nothing, and the welcome grant rides
the org create exactly once.

## Feature flags

Staging/prod divergence is feature flags only — a `FeatureFlag` Ash
resource (key, enabled, optional rollout %) administered via
**AshAdmin** ([ADR-0027](adr/00027-admin-surface-ashadmin.md); the
curated view is deferred until generated CRUD annoys), separate
values per environment via separate databases. Flags gate *features*,
never schema. Delete flags on a schedule.

## Migration rules (load-bearing)

Simultaneous deploy lands code+schema everywhere at once; rolling
windows and rollbacks still require additive-only discipline:

1. A release ships **only additive** migrations; destructive changes
   ride a later "contract" release.
2. Review every generated migration — `DROP`, `ALTER`, new `NOT NULL`
   demand scrutiny (Ash codegen renders renames/removals as drops).
3. Backfills are batched release tasks or background jobs, never
   inline migrations.
4. New enum states and new Oban arg shapes wait a full deploy cycle
   before anything writes them.
5. `CREATE INDEX CONCURRENTLY` for indexes on real tables
   (`@disable_migration_lock`).

One-way doors (prevention only — what gate-on-demand is for):
overwriting backfills, data-losing column type changes, dropped
columns with data, **Postgres enum value removal** (unsupported —
requires type recreation), destructive rewrites.

### Gate-on-demand

Default is simultaneous deploy. For a scary migration (table rewrite,
risky constraint): pin prod in the fleet repo (one line), let staging
run it, prove it, release. Opt-in gate, not standing.

## Rollback protocol

**Rollback = roll forward through the same pipeline.** Never `kubectl
rollout undo` (Flux reasserts git state within minutes), never
`ecto.rollback` outside dev, never delete an applied migration file.

| Failure | Response |
|---|---|
| Broken deploy, no migration | Revert the app PR → new image → Flux rolls both envs. Done. |
| Additive migration, feature broke | **Revert code only; leave schema — but only if the schema remains write-compatible with the previous image** (nullable additions yes; new `NOT NULL`/constraints the old code can't satisfy → harmful-migration row). Orphaned additive schema is harmless; clean up in a later contract release. The default — counter-migrations are rare
   ([ADR-0014](adr/00014-rollback-protocol.md) Am. 1). |
| Harmful migration itself | Revert PR = code revert **+ counter-migration** (new migration N+1): revert the resource code, let the Ash migration generator diff the undo, review. One deploy, code and schema revert in lockstep. |
| One-way door | Fix forward or restore from backup. |

Manifest-caused failures (bad limits, Traefik config): revert the
**fleet repo** PR — same protocol, different repo.

## On failure: automate detection and preparation, keep the decision human

On **deploy-gated** smoke failure, automation **alerts** (email,
deep-linked), **opens the revert PR** (`gh pr revert <n>`) and
dispatches CI onto its branch (CI-opened PRs fire no events of their
own), comments on the offending PR, posts a Grafana annotation. A
human merges (one tap) or writes the proper counter-migration PR. No
auto-merge. One structural limit: CI's own token cannot push commits
touching `.github/workflows` — a workflow-touching PR reverts by hand;
the comment says so when it happens. **Scheduled** failures get the
annotation only — no revert PR (nothing deployed to blame); they page
via the heartbeat dead-man above.

Upgrade path to auto-revert (only if the smoke suite proves weeks of
near-zero flakiness AND deploys start happening while AFK): auto-merge
the prepared revert **only when the diff contains no files under
`priv/repo/migrations`** — migration-touching failures always
escalate to a human.
