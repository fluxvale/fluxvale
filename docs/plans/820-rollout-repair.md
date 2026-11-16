# Plan: repair wedged rollout_failed instances and bound the no-op cadence (#820)

**Status**: GO 2026-11-16 (Terence) — all recommendations taken:
D1 reconciler converge arm, D3 3600s window + fallback posture, D5a
unwedge now (S1 first), D5b skip local-k3d e2e. Slices 2–5 flash-pinned.
**Scope**: platform repo + one staging mutation (the dogfood unwedge,
our own instance, evidence below). No ops-repo writes. Continues
[#776](776-instance-restart-strategy.md) Slice 5's deferred recovery.
**Worktree**: `~/Work/FluxVale/fv820-rolloutrepair`, branch
`docs/rollout-repair-plan`.

## Verified ground truth (re-verified 2026-11-16 ~09:50–10:00Z)

Everything below was re-read from primary sources this session; the
#818 findings doc was not yet persisted when this plan was written.

- `stg-thrumming-hill-9288` (memos, ns
  `fluxvale-app-01a1d745-7bc4-758c-84d7-2819075f75e9`): `error` /
  `rollout_failed` since 2026-11-13 23:39Z. Live Deployment:
  `strategy 25%/25%`, `generation=2 observed=2 updated=0 ready=1` —
  the issue's `0 < 1` verbatim. `ReplicaFailure=True/FailedCreate:
  exceeded quota: app-quota` (quota = exactly one pod: 250m/250m cpu
  requests). Old pod `app-669b667dfd` Running 2d10h, serving the
  stale env; pending RS `app-8699c89bff` holds the Nov-13 env revision
  with zero pods.
- Staging platform `/health` = `sha-9bae698c` = current main HEAD, so
  **#781 is live and provably cannot reach this row**: the strategy
  normalize lives in `Deployment.scale/restart/ensure_env_from`
  (`prepare_for_apply/2`, `deployment.ex:786–803`), none of which run
  against an `:error` row. Recovery gates on
  `current_revision_ready?` (`reconcile_instance.ex:352–362`),
  permanently false; the pod is scheduled, so not `:no_capacity`
  either — `recover_if_ready/3`'s no-op arm (`:218–224`) returns
  forever.
- Job cadence, measured: 1 reconcile job/minute/wedged-row (AshOban
  scheduler `* * * * *` enqueues per matching row per tick); staging
  totals ~6 reconcile jobs/min (5 rows + scheduler) across all
  instances. The issue's "~2,200 no-op jobs/min" is not reproducible
  per-row at this scheduler — treat it as #818's fleet/queue
  aggregation. The verified harm is **unbounded duration**: 1
  job/min/row forever, with K8s GETs, span emission, and Oban row
  churn (pruned at 7d). No-op passes do **not** write the row (the
  09:45:02Z `updated_at` was the `*/15` settler, not the reconciler).
- The four Oct-23 zombies (`stg-cold-bush-3834`, `stg-autumn-snowflake-3155`,
  `stg-broken-hill-3730`, `stg-restless-haze-6738`): all
  `deploy_failed`, message `Traefik middleware forbidden` (RBAC class).
  Already excluded from the reconcile trigger and from
  `InstanceFailureReason.recoverable/0` — the owner `deploy` retry
  owns them. Prod: 1 instance, 0 errors.

## Design

### The repair (D1) — reconciler converges the Deployment strategy

**Live finding (S1, 2026-11-16 10:05Z)**: a strategy-only SSA does
unwedge the quota (old pod reaped, strategy `0/1`, gen bumped) — but
the long-wedged ReplicaSet carries ~16 min of accumulated
RS-controller create backoff (events 09:13→09:30→09:46→10:03), so the
replacement pod only appears on the next organic retry. The repair
must therefore be **restart-shaped**: strategy normalize **plus** the
`fluxvale.io/restartedAt` annotation bump — exactly what the existing
#781-tested `Deployment.restart/4` does — so a fresh ReplicaSet with
no failure history rolls within seconds, inside the freed quota.

Two pieces:

- New client predicate `Deployment.strategy_diverges?/3`
  (`deployment.ex`): GET the Deployment, compare `spec.strategy`
  against `@rollout_strategy` (exact-equality; SSA round-trips the
  integers — pinned by test) → `{:ok, boolean}` | `{:error, e}`.
- The recovery arm calls it; on divergence it calls the **existing**
  `Deployment.restart/4` (GET → `prepare_for_apply` forces the one-pod
  strategy → annotation bump → SSA, manager `fluxvale` — one module
  attribute, the posture cannot fork) and records
  `reconcile_repaired_at`. On convergence it parks (below).
  Idempotent: after one restart the strategy matches, so the arm never
  restarts again; `restart` itself is #781's tested path.

Why not the alternatives:
- **Owner-only repair** (deploy retry, which exists and works): every
  current and future wedge needs manual action; the issue asks for
  convergence. Kept as the owner path of last resort, unchanged.
- **One-off fleet backfill**: redundant — every touch path
  (restart/scale/env-update) already normalizes post-#781, and this
  repair catches any row that wedges despite that (including
  externally-caused template bumps). No release task.

### The recovery gate (D2) — same readiness, active convergence

The **promotion** gate stays `current_revision_ready?` — "current
revision replicated and ready" is the definition of healthy and must
not change. What changes is the arm *before* it: recovery stops being
read-only-waiting for a condition that provably cannot happen and
instead **makes the revision reachable**. New convergence contract:

> A `rollout_failed` row recovers when its Deployment carries the
> one-pod strategy and the current revision is ready. The reconciler
> converges the strategy itself (idempotently); a row that still
> cannot converge is parked at bounded cadence instead of churning.

After the converge, the existing tail does the rest unmodified:
pending revision rolls → `updated: 1` → `current_revision_ready?` →
`repair_env_and_promote` (env Secret projection + restart) →
`:running`. Expect the second roll: the promote path restarts once
when `env_vars` is non-empty — harmless, it guarantees Secret ≡ row.

### The no-op storm guard (D3) — grace, then parking with hourly readmission

Two nullable timestamps on Instance (`public? false`, no API/OpenAPI
churn), migration via `mix ash.codegen add_instances_reconcile_parking`:

- `reconcile_repaired_at` — the repair's grace anchor, written by the
  pass that restarts. A repair gets the deploy-stale bound (300s,
  `@deploy_stale_timeout_seconds` — house precedent) to converge
  before parking engages: a restart-shaped roll is ready in ~1–2 min,
  so the fast cadence holds exactly as long as the roll needs and the
  promote lands on the next minute's pass.
- `reconcile_parked_at` — written by a no-progress pass (strategy
  converged, still not ready, **and** `repaired_at` older than 300s)
  **only when nil or older than the window** (write-once-per-window),
  via a dedicated internal `update :park_reconcile` action mirroring
  `update_status`'s `authorize?: false` shape. Window: **module
  attribute on the Instance resource, exposed via a public accessor
  for the reconciler's predicate — one source for the trigger
  fragment and the write-once check (no config knob; tests seed
  timestamps directly, nothing overrides the window at runtime)**.
- The trigger `where` (`instance.ex:253–259`) gains:
  `(is_nil(reconcile_parked_at) or
  fragment("? < now() - interval '3600 seconds'", reconcile_parked_at))`
  — parked rows stop being *enqueued* (job churn stops), and the
  window readmits them hourly so external healing (quota raised,
  cluster repair) still promotes. **Spike first** (S3 step 1):
  confirm `fragment` compiles inside an AshOban trigger `where`
  (precedent: `personal_access_token.ex:386` uses fragment in Ash
  exprs). Fallback if it doesn't: worker-side early-discard at the
  `call/1` head (fresh parking marker → return immediately, no K8s
  calls) — work-free but rows still enqueue; documented residual,
  decided at the spike.
- Every status write clears both markers: `update_status` (the one
  funnel) forces them nil, so a re-wedge or any transition resumes the
  fast cadence. An apply-erroring repair parks on the same predicate
  (the restart did not land, no grace earned) — nothing churns forever.
- Scope: `rollout_failed` only. `stuck`/`missing`/`start_failed`
  no-ops are rare and recover through the existing gate; `nil`-reason
  legacy rows are not repaired (no known population — staging and
  prod both show none; accepted limitation, noted in the ADR).

Net effect per wedged row: from 1 job/min forever to ≤1 job+write per
hour, with promotion still ≤1 min after the blocker clears.

### deploy_failed zombies (D4) — untouched, by design

No code change. They are already out of the queue and out of
`recoverable/0`; the owner `deploy` retry is their exit, and
teardown / the pre-launch wipe is an owner decision on the #818 lane.
Parking never applies to them (they never enqueue). They stay
`:error`, so the "Instances stuck in error" alert keeps counting
them — correct: they *are* failed; #818 owns the delivery-path half.

## Decisions for Terence

- **D1** repair mechanism: reconciler strategy-converge arm
  (recommended, above) vs owner-only.
- **D3** parking window 3600s (vs 900 / 86400) and the
  fragment-vs-worker-discard fallback posture.
- **D5a** staging unwedge timing: immediately after GO, before the PR
  (recommended — stops serving stale env this week; independent of
  the release train).
- **D5b** optional local-k3d end-to-end proof of the automated arm
  (deploy an instance on the dev stack, wedge it via kubectl
  strategy+template bump, watch the fix converge it; ~15 min of
  deadline waits): include, or unit+staging evidence suffices
  (recommended: suffices — the unit regression test reproduces the
  wedge class exactly).

## Slice 1 — staging unwedge (D5a; architect-run, post-GO, mutation with evidence)

The manual form of exactly what the fix will do automatically — same
manager, same strip, same strategy. Mirrors `prepare_for_apply`.

```sh
CTX=admin@fluxvale
NS=fluxvale-app-01a1d745-7bc4-758c-84d7-2819075f75e9
# BEFORE (evidence): row, strategy, status handshake, event count
kubectl --context $CTX -n fluxvale-db exec fluxvale-cnpg-1 -- psql -U postgres -d platform_staging -c \
  "SELECT slug,status,failure_reason,updated_at FROM instances WHERE slug='stg-thrumming-hill-9288';"
kubectl --context $CTX -n $NS get deploy app -o jsonpath='{.spec.strategy} gen={.metadata.generation} obs={.status.observedGeneration} updated={.status.updatedReplicas} ready={.status.readyReplicas}{"\n"}'
kubectl --context $CTX -n $NS get events --field-selector reason=FailedCreate -o json | jq '[.items[] | (.series.count // .count // 1)] | add'
# THE REPAIR: strip managedFields, force the one-pod strategy, SSA as the platform's manager
kubectl --context $CTX -n $NS get deploy app -o json \
  | jq 'del(.metadata.managedFields) | .spec.strategy = {"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}' \
  | kubectl --context $CTX -n $NS apply --server-side --field-manager fluxvale -f -
# AFTER: pending revision rolls (old pod down, RS app-8699c89bff pod up), then the
# reconciler promotes within ≤2 min (expect the second roll from repair_env_and_promote)
kubectl --context $CTX -n $NS rollout status deploy/app --timeout=300s
kubectl --context $CTX -n $NS get deploy app -o jsonpath='{.spec.strategy}{"\n"}'
kubectl --context $CTX -n $NS get pods -o wide
# row lands :running; FailedCreate series.count frozen from the repair onward
```

Fallback if raw SSA surprises: RPC through the staging platform
(`/app/bin/flux_vale rpc` → `InstanceEnvSecret.restart/2`, which
normalizes strategy via the live #781 code) — creates one extra
revision, same convergence.

**Done when**: transcript with before/after (row `:running`, strategy
`0/1`, `updated=1 ready=1`, pending-RS pod running = the Nov-13 env
revision live, FailedCreate count frozen) attached to #820 by the PA.

**S1 result (2026-11-16 10:05–10:22Z, executed)**: strategy-only SSA
freed the quota (old pod reaped 10:05:04Z) but the wedged ReplicaSet's
~16-min create-backoff delayed the replacement pod to the 10:20:09Z
organic retry — the finding that made the automated repair
restart-shaped (D1). The current staging code then finished unaided:
`updated=1 ready=1` at 10:20:20Z, promote at 10:21:01Z (env
re-projection + the expected second roll, its 6-event maxSurge-0
handoff burst at 10:21:01Z, then silence), row `:running`, app
serving 200, FailedCreate frozen, reconcile back to the healthy 5/min
mirror cadence. Full transcript: `/tmp/opencode/820-s1-transcript.md`
(PA attaches to #820).

## Slice 2 — client `strategy_diverges?/3` (worker)

**Files**: `apps/platform/lib/flux_vale/clients/k8s/resources/deployment.ex`,
`apps/platform/test/flux_vale/clients/k8s/resources/deployment_test.exs`.

**Change**: `strategy_diverges?/3` as in D1 — GET + exact-equality
compare of `spec.strategy` against `@rollout_strategy`. `@doc` names
#820 and points at the reconciler arm as its only caller; the repair
itself is the existing `restart/4` (unchanged).

**Tests**: fetched 25%/25% → `{:ok, true}`; fetched converged
(integers, the SSA round-trip form) → `{:ok, false}`; GET error
propagates. No apply happens in this predicate — that's `restart/4`'s
already-tested job (`deployment_test.exs:642–661`).

**Done when**:

```sh
cd apps/platform
MIX_TEST_PARTITION=820s2 mix test test/flux_vale/clients/k8s/resources/deployment_test.exs
```

`0 failures`, plus `mix format --check-formatted` and
`mix credo --strict` on the touched files.

## Slice 3 — parking plumbing (worker; after/parallel with S2)

**Files**: `…/resources/instance.ex` (both attributes, `update
:park_reconcile` action, `update_status` clears both markers, trigger
`where` fragment), generated migration (prefer a `change
set_attribute` on `update_status` over touching `instance_k8s.ex`),
`test/flux_vale/contexts/infrastructure/instance_test.exs`,
`test/flux_vale/contexts/infrastructure/operations/restoring_state_test.exs`
(the 114–130 exact-admission block gains the parked-exclusion cases),
`config/config.exs` only if the window needs a test override (prefer
compile-env default, no config line).

**Step 1 is the fragment spike**: assert the trigger compiles and the
scheduler query filters (`MIX_ENV=test mix ash.setup` fresh, then the
restoring_state tests). Fallback decision per D3 recorded in the PR
body if fragment fails.

**Tests**: parked-fresh row excluded, parked-stale row admitted,
nil-marker admitted; `update_status` clears both markers;
`park_reconcile` writes only when stale (two calls, one write).

**Done when**:

```sh
cd apps/platform
MIX_TEST_PARTITION=820s3 mix test test/flux_vale/contexts/infrastructure/instance_test.exs \
  test/flux_vale/contexts/infrastructure/operations/restoring_state_test.exs
mix ash.codegen --check
```

## Slice 4 — reconciler repair arm + regression tests + ADR (worker; after S2+S3)

**Files**:
`…/operations/reconcile_instance.ex` (the D1 arm, grace + `park/1`,
moduledoc contract line), `reconcile_instance_test.exs`,
`docs/adr/00005-customer-instances-as-namespaces.md` (Amendment 7),
`docs/adr/README.md` (index row).

**Regression tests reproducing the wedge class** (the lane's core
deliverable):

1. Wedge repro, two passes: `error`/`rollout_failed` row; Deployment
   status stub `replicas: 1, ready: 1, updated: 0`, generation
   handshake OK, scheduled pod, fetched strategy 25% → pass 1 asserts
   `restart` applied (strategy 0/1 + annotation bump, managedFields
   stripped) and **no status write**, `reconcile_repaired_at` set;
   pass 2 stubs `updated: 1, ready: 1` → promote (env projection +
   `:running`). This is lines 431–450's entry test and 783–880's
   recovery tests joined at the waist — the deadlock reproduced, then
   closed.
2. Converged strategy, not ready, `repaired_at` fresh (<300s) → no
   restart, no park — the grace holds the fast cadence for the roll.
3. Converged strategy, not ready, `repaired_at` stale → parked
   (marker written, write-once-per-window).
4. Restart apply error → logged warning, parked (no grace earned).
5. `stuck`/`missing`/`start_failed` rows: no restart (scope).
6. Unschedulable pod → `:no_capacity` still wins over repair.
7. `deploy_failed` not in the reconciled set (existing tests hold).

**Amendment 7 draft** (short, per house style): the reconciler
converges a `rollout_failed` row's Deployment strategy to the one-pod
posture (#781's constant) before gating on revision readiness; a row
that cannot converge parks at `:reconcile_park_window_seconds`
cadence; readiness promotion is unchanged; `deploy_failed` stays
owner-owned.

**Done when**:

```sh
cd apps/platform
MIX_TEST_PARTITION=820s4 mix test test/flux_vale/contexts/infrastructure/operations/reconcile_instance_test.exs
```

## Slice 5 — assembly + PR (worker)

One PR, one concern: `fix(platform): converge wedged rollout_failed
instances within the one-pod quota` — `Closes #820`. Body pre-empts
predictable findings (why the gate stays, why parking is a column, the
spike outcome or fallback), links the Slice-1 staging evidence.
Slices 2–4 land as commits on one branch; `MIX_TEST_PARTITION=820 mix
ci` green; screenshots N/A (no user-visible surface change — the row
was already `error`/`rollout_failed` copy). Board: In Review at PR
open, Done on merge.

## Overall lane Done when

1. Staging memos instance unwedged with transcript evidence (Slice 1).
2. The regression test reproducing the wedge class green in CI
   (Slice 4 test 1).
3. `MIX_TEST_PARTITION=820 mix ci` green; PR merged per the review
   budget; board card Done.
4. Post-merge staging check (next release train): zero
   `rollout_failed` rows wedged; the four `deploy_failed` zombies
   remain owner-owned (unchanged, per D4).

## Boundaries

- #818's alert-delivery investigation is untouched by this plan; the
  zombies' teardown / pre-launch wipe decision stays with the owner.
- No quota change, no strategy change beyond #781's constant, no new
  user-facing copy, no OpenAPI surface change.
- The `nil`-reason legacy rows and non-quota wedges (bad image
  crashloops) park rather than repair — owner action remains their
  exit, exactly as today, minus the endless churn.
