# Plan: instance updates that roll inside the one-pod quota (#776)

**Status**: Implemented (Slices 1–3) — Terence's GO 2026-11-14, option
**A** (D1 settled). Slice 4 (provider repo) and Slice 5 (staging proof)
remain open. Implemented in `~/Work/FluxVale/fv776-restart`, branch
`fix/instance-restart-strategy`.
**Scope**: platform repo only. No ops-repo writes (`jobs/fluxvale/` is the PA's).
The provider repo (`terraform-provider-fluxvale`) docs/acceptance follow-up is
a separate PR — see [Slice 4](#slice-4--provider-repo-follow-up).

**Added at GO** (same scope): a distinct `no_capacity` state (a scheduler
rejection is not a crash; the pod condition reason rides in
`status_message`), and stuck-`:error` recovery (an unintended failure
whose workload is healthy lands `:running`). Both are implemented per
Slices 2 and 3 below.

## Verified root cause

- `apps/platform/lib/flux_vale/clients/k8s/resources/deployment.ex` built
  `spec` without `strategy` (pre-#776 code, line anchors as of
  `b6f1bcde`: lines 543–555), so the API applied `RollingUpdate` with
  `maxSurge: 25%` / `maxUnavailable: 25%`.
- `apps/platform/lib/flux_vale/clients/k8s/resources/resource_quota.ex`
  (lines 131–139) hard-caps `requests.cpu/memory` and `limits.cpu/memory`
  at exactly one pod's size.
- `apps/platform/lib/flux_vale/contexts/infrastructure/operations/reconcile_instance.ex`
  (`transition_for/2`, lines 171–194) flips `:starting`/`:running` to
  `:error` on any `ReplicaFailure: True` (line 210) or
  `Progressing: False` + `ProgressDeadlineExceeded` (lines 212–217).
  `:error` is not reconciled again (`call/1` only covers
  `:deploying`/`:starting`/`:running`), so the flip is sticky.

Live staging evidence (2026-11-13/14, namespace
`fluxvale-app-01a1d745-7bc4-758c-84d7-2819075f75e9`, instance
`stg-thrumming-hill-9288`, deployment `app`):

```
$ kubectl --context admin@fluxvale -n <ns> get deploy app \
    -o jsonpath='{.spec.strategy}'
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}

$ kubectl ... get resourcequota app-quota -o jsonpath='{.status.hard}'
{"limits.cpu":"500m","limits.memory":"1Gi",...,"requests.cpu":"250m",...}

$ kubectl ... get events --field-selector reason=FailedCreate
Warning FailedCreate replicaset/app-8699c89bff Error creating: pods
"app-8699c89bff-rkjpx" is forbidden: exceeded quota: app-quota, requested:
limits.cpu=500m,limits.memory=1Gi,requests.cpu=250m,requests.memory=512Mi,
used: <same>, limited: <same>

$ kubectl ... get deploy app -o jsonpath='{.status.conditions}'
ReplicaFailure=True/FailedCreate  ("exceeded quota")
Progressing=False/ProgressDeadlineExceeded  (10 minutes after the update)

$ curl -sk -o /dev/null -w '%{http_code}' https://stg-thrumming-hill-9288.fluxvale.app/
200   # the old pod never stopped serving

$ kubectl ... exec deploy/fluxvale-platform -c platform -- \
    /app/bin/flux_vale rpc '...Instance.get_by_id!("01a1d745-...").status ...'
STATUS=error REASON=:rollout_failed
MSG=Deployment failed: FailedCreate: pods "app-8699c89bff-rkjpx" is
forbidden: exceeded quota: app-quota, ...
```

The old pod `app-669b667dfd-w7hb8` was `1/1 Running`; the new ReplicaSet
`app-8699c89bff` had `DESIRED 1` and zero pods.

**Local k3d proof of the handoff window** (throwaway namespace, exact
one-pod quota, `traefik/whoami:v1.10`, then deleted):

```
# maxSurge: 0 / maxUnavailable: 1
00:32:16 pods=[app-79f645899d-bqs2b:Terminating] failedcreate_events=5 replicafailure=[True/FailedCreate]
00:32:17 pods=[app-54c557ffbd-kdqsv:ContainerCreating] failedcreate_events=6 replicafailure=[]
00:32:18 pods=[app-54c557ffbd-kdqsv:Running] failedcreate_events=6 replicafailure=[]
# six FailedCreate events in the ~1s handoff; the condition clears when the
# replacement pod is created.

# Recreate
failedcreate_before=6
00:33:07 pods=[app-54c557ffbd-kdqsv:Terminating] failedcreate_events=6 replicafailure=[]
00:33:08 pods=[app-7585575986-mcdjc:ContainerCreating] failedcreate_events=6 replicafailure=[]
00:33:10 pods=[app-7585575986-mcdjc:Running] failedcreate_events=6 replicafailure=[]
# zero new FailedCreate events: Recreate waits for the old pod object to go.
```

Why: quota charges a terminating pod until the pod object is gone (or
`deletionTimestamp + gracePeriod` expires), while the Deployment's rolling
path treats a pod with a deletion timestamp as inactive and creates the
replacement. MaxSurge 0 therefore emits a short `FailedCreate` burst on
every roll. This is the one open decision — see **D1**.

## Decisions

**Settled by the issue**

- No quota change. One pod is the product cap ([ADR-0005](../adr/00005-customer-instances-as-namespaces.md)).
- No stop/start workaround in the docs once the fix ships.
- A real `FailedCreate` still reaches `:error`; a progressing rollout does not.

**Settled at GO**

- **D1 — A.** Terence chose `maxSurge: 0` / `maxUnavailable: 1`: accept
  the ~1s handoff `FailedCreate` burst and tolerate it in reconcile (fresh
  `ReplicaFailure` is retried; terminal only after 300s or
  `ProgressDeadlineExceeded`). B (`Recreate`) and C (scripted
  stop/start) are rejected: B drops the rolling/readiness shape, C is
  more orchestration for no better downtime.

**Open — needs Terence**

- **D2 — provider repo follow-up.** The instance card and secrets guide
  live in `fluxvale/terraform-provider-fluxvale`, not this repo. A separate
  PR is needed for the card/guide/acceptance changes (Slice 4).
- **D3 — staging proof credential/target.** Needs a staging PAT with
  `instances:read` + `instances:write`, and the incident instance (owner:
  Terence). The commands below use the incident instance; substitute any
  running staging instance if that one is not the right target.

## Slice 1 — strategy in the manifest, converged on every apply

**Files**

- `apps/platform/lib/flux_vale/clients/k8s/resources/deployment.ex`
- `apps/platform/test/flux_vale/clients/k8s/resources/deployment_test.exs`

**Change**

Add one module attribute and use it in both the builder and every
GET→apply path:

```elixir
@rollout_strategy %{
  "type" => "RollingUpdate",
  "rollingUpdate" => %{"maxSurge" => 0, "maxUnavailable" => 1}
}
```

In `build_manifest/3`:

```elixir
"spec" => %{
  "replicas" => Map.get(spec, :replicas, @default_replicas),
  "strategy" => @rollout_strategy,
  "selector" => ...
}
```

Rename `strip_managed_fields/1` to `prepare_for_apply/1` and make it force
the strategy, not just drop `managedFields`:

```elixir
# Every GET→apply path goes through here. A Deployment created before
# the one-pod strategy existed has the API default persisted; applying
# the fetched object verbatim would keep maxSurge 25%. Force the
# one-pod strategy alongside the managedFields strip.
defp prepare_for_apply(resource) when is_map(resource) do
  metadata = resource |> Map.get("metadata", %{}) |> Map.delete("managedFields")
  spec = resource |> Map.get("spec", %{}) |> Map.put("strategy", @rollout_strategy)

  resource
  |> Map.put("metadata", metadata)
  |> Map.put("spec", spec)
end
```

Call it from `scale/4`, `restart/4`, and `ensure_env_from/3` (all three
currently call `strip_managed_fields/1`). This is load-bearing: the env
update path (`UpdateEnv` → `InstanceEnvSecret.restart/2`) GETs and
re-applies the existing Deployment, so without this an existing staging
instance would still roll at 25%.

**Rationale for maxSurge 0 / maxUnavailable 1**

- `maxSurge: 0`: no second pod can be admitted by the one-pod quota; no
  quota change, no extra spend.
- `maxUnavailable: 1`: allows the old pod to be taken down so the new one
  can be created. `maxUnavailable: 0` with `maxSurge: 0` deadlocks.
- `RollingUpdate` over `Recreate`: keeps the Deployment's availability
  accounting and readiness gating. `Recreate` is a hard stop/start and
  gives up the rollout's health gates — see D1 for the trade-off.
- Doubling the quota: rejected. It doubles namespace spend and lets a
  scaled Deployment spend it, against ADR-0005's one-pod cap.

**Single-replica rollout shape**

1. The pod template changes (env annotation bump or spec apply).
2. The controller scales the old ReplicaSet to 0: old pod gets SIGTERM,
   terminates (brief zero-availability window).
3. The new ReplicaSet scales to 1; the scheduler places the pod;
   `startupProbe` (5s × 18) then `readinessProbe` (5s × 3) gate it.
4. Ready → `availableReplicas: 1`, `Progressing: True /
   NewReplicaSetAvailable`; the Deployment is complete.
5. The reconcile keeps the instance `:running` (or moves `:starting` →
   `:running` once ready). It must not treat the handoff
   `ReplicaFailure` as terminal (Slice 2).

**Tests**

- New manifest test: `get_in(manifest, ["spec", "strategy"]) ==
  %{"type" => "RollingUpdate", "rollingUpdate" => %{"maxSurge" => 0,
  "maxUnavailable" => 1}}`.
- New `restart/4` test: stub `Kubereq.get` with a fetched Deployment
  carrying the old `25%` strategy; assert the applied manifest carries
  `maxSurge: 0` / `maxUnavailable: 1` (and the annotation still bumps).
- Extend the existing `scale/4` test: assert the applied manifest
  carries the same strategy.

**Done when**

```sh
cd /home/terence/Work/FluxVale/fv776-restart/apps/platform
mix format --check-formatted
mix test test/flux_vale/clients/k8s/resources/deployment_test.exs
```

Expected: `mix format` exits 0; ExUnit prints `0 failures` (the strategy
test plus the existing deployment suite green).

## Slice 2 — reconcile tolerates the handoff, errors on a real failure

**Files**

- `apps/platform/lib/flux_vale/contexts/infrastructure/operations/reconcile_instance.ex`
- `apps/platform/test/flux_vale/contexts/infrastructure/operations/reconcile_instance_test.exs`
- `docs/adr/00005-customer-instances-as-namespaces.md` (Amendment 6)
- `docs/adr/README.md` (index row: Amendments 1–6)

**Conditions/fields used**

- `conditions[type=ReplicaFailure].status` / `reason` / `message` /
  `lastTransitionTime` (the timestamp is the RS condition's start; the
  Deployment controller copies it via `ReplicaSetToDeploymentCondition`).
- `conditions[type=Progressing].status` / `reason`.
- `replicas` / `ready` (existing readiness promotion).
- Timeout: the existing `@deploy_stale_timeout_seconds` (300s,
  `:deploy_stale_timeout_seconds` compile env). Reused as the rollout
  failure bound; `stale_deploy?/1` and the `:deploying` path stay
  untouched.

**Rule**

- **Terminal**: `Progressing: False` + `reason:
  ProgressDeadlineExceeded` (Kubernetes' own 600s progress deadline), or
  a `ReplicaFailure: True` whose `lastTransitionTime` is older than
  300s, or a `ReplicaFailure` with a missing/unparseable timestamp
  (defensive: K8s always emits one).
- **Not terminal**: a fresh `ReplicaFailure: True` while the rollout is
  progressing. The ReplicaSet controller retries the pod create; the
  terminating old pod releases the quota when it goes. Log a warning
  with the condition message and keep the current status.
- `rollout_failure_message/1` stays as-is: it prefers the
  `ReplicaFailure` message, so the `status_message` still names the real
  reason (`FailedCreate: ...`) when the failure lands.

Sketch:

```elixir
defp failed_rollout?(conditions) do
  Enum.any?(conditions, &failure_condition?/1)
end

defp failure_condition?(%{"type" => "ReplicaFailure", "status" => "True"} = condition) do
  stale_condition?(condition)
end

defp failure_condition?(%{
       "type" => "Progressing",
       "status" => "False",
       "reason" => "ProgressDeadlineExceeded"
     }),
     do: true

defp failure_condition?(_condition), do: false

defp stale_condition?(%{"lastTransitionTime" => timestamp}) do
  case DateTime.from_iso8601(timestamp) do
    {:ok, at, _offset} ->
      DateTime.diff(DateTime.utc_now(), at, :second) > @deploy_stale_timeout_seconds

    {:error, _reason} ->
      true
  end
end

defp stale_condition?(_condition), do: true
```

`transition_for/3` order (as implemented):

1. `desired > 0 and current_revision_ready?` (`ready >= desired` **and**
   `updated >= desired`) → promote `:starting` to `:running`, no-op for
   `:running`. Readiness wins over leftover conditions, but only for the
   CURRENT revision: a ready old pod must not mask a stalled new spec.
2. An unschedulable newest pod → `:no_capacity` with the condition
   reason. This arm precedes `failed_rollout?`, so
   `ProgressDeadlineExceeded` and the 300s bound do not turn a scheduler
   rejection into `:error`.
3. `failed_rollout?` (stale `ReplicaFailure` or
   `ProgressDeadlineExceeded`) → `:error` (`:rollout_failed`).
4. A fresh `ReplicaFailure` present → log and return `{:ok, instance}`
   (no write).
5. Otherwise no-op.

`:error` also joins the reconciled statuses. A recoverable (unintended)
failure whose current revision is ready promotes to `:running`; an
unschedulable pod lands `:no_capacity`; intent-bearing failures stay
error. `:no_capacity` reconciles the same way: ready → `:running`,
schedulable again → `:starting`, still unschedulable → no-op, owner stop
→ `:stopped`.

**Status transitions**

| Current | Signal | Outcome |
|---|---|---|
| `:running` | fresh `ReplicaFailure` (≤300s), not ready | stays `:running` (no write) |
| `:starting` | fresh `ReplicaFailure` | stays `:starting` (no write) |
| `:running` / `:starting` | `ReplicaFailure` >300s or bad timestamp | `:error`, `failure_reason: :rollout_failed` |
| `:running` / `:starting` | `Progressing: False` + `ProgressDeadlineExceeded`, not ready | `:error`, `:rollout_failed` |
| any reconciled state | `ready >= replicas`, `updated >= replicas`, `desired > 0` | `:running` (the current revision outranks leftover conditions) |
| `:starting` / `:running` | newest pod `PodScheduled=False` / `Unschedulable` | `:no_capacity`, reason in `status_message` |
| `:starting` / `:running` | unschedulable **and** `ProgressDeadlineExceeded` / >300s | stays `:no_capacity` (capacity wins over the rollout deadline) |
| `:error` (recoverable reason) | current revision ready | `:running` |
| `:error` (recoverable reason) | pod unschedulable | `:no_capacity` |
| `:error` (`:stop_failed`/`:restore_failed`/`:teardown_failed`) | any | stays `:error` |
| `:no_capacity` | current revision ready | `:running` |
| `:no_capacity` | pod scheduled, not ready | `:starting` |
| `:no_capacity` | still unschedulable | no-op |
| `:no_capacity` | owner stops | `:stopped` |
| `:deploying` | `deployed_at` >300s | `:error`, `failure_reason: :stuck` (unchanged) |

Why this is safe: the local proof shows the handoff condition clears in
about a second; a real bad spec (invalid image/spec) keeps the
`ReplicaFailure` condition until the pod is ever created, so it crosses
300s and errors. A real crash-loop still reaches the existing
`ProgressDeadlineExceeded` arm. A scheduler rejection stays
`:no_capacity` — the deadline is not evidence of a crash when no pod has
been placed yet — and the owner can stop it (→ `:stopped`) to resize
down.

**Tests**

- `:running` + `Progressing: True` + fresh `ReplicaFailure: True` /
  `FailedCreate` (quota message, `lastTransitionTime` = now) → stays
  `:running`; assert no status write (`updated_at` unchanged).
- `:starting` + fresh `ReplicaFailure` → stays `:starting`.
- `:running` + `ReplicaFailure` with `lastTransitionTime` 301s old →
  `:error`, `status_message` contains `FailedCreate`/the message,
  `failure_reason: :rollout_failed`.
- `:starting` + `ReplicaFailure` with `lastTransitionTime: "not-a-time"`
  → `:error` (covers the parse-error arm).
- Existing `ProgressDeadlineExceeded` test stays green.
- Existing deploy-stale tests stay byte-identical and green — the
  `:deploying` timeout is not touched.

Update the module doc bullet (lines 11–12) to the new contract and add
ADR-0005 Amendment 6 with the maxSurge 0 / grace rationale.

**Done when**

```sh
cd /home/terence/Work/FluxVale/fv776-restart/apps/platform
mix test test/flux_vale/contexts/infrastructure/operations/reconcile_instance_test.exs
```

Expected: `0 failures`; the stale-deploy describe block runs unchanged.

## Slice 3 — docs in this repo

**Files**

- `docs/public/automation/terraform.md` (line 183)
- `docs/adr/00005-customer-instances-as-namespaces.md` (Amendment 6, if
  not landed with Slice 2)
- `docs/adr/README.md`

**Change**

Replace the stop/start workaround paragraph with:

> The platform rolls a running app after an env change. The rollout takes
> the old pod down before the new one starts — one pod at a time, within
> the instance's existing quota — so expect a short restart and no
> stop/start.

Keep the ADR amendment short: the explicit strategy, the handoff
`ReplicaFailure` retry, and the 300s / `ProgressDeadlineExceeded` terminal
signals. Draft:

```markdown
## Amendment 6 (2026-11-14)

Per #776: the instance Deployment carries an explicit `RollingUpdate`
strategy with `maxSurge: 0` / `maxUnavailable: 1`. The namespace quota is
sized for exactly one pod, so a surge pod can never be admitted; a rollout
takes the old pod down before the new one starts (a short restart), and a
running env/spec update no longer needs a stop/start.

Reconcile treats `ReplicaFailure` as retryable while it is fresh: the
ReplicaSet controller retries a rejected pod create, and a terminating pod
holds the quota until it is gone. A failure flips the instance to `:error`
only after it outlives the deploy-stale bound (300s) or Kubernetes reports
`Progressing: False` / `ProgressDeadlineExceeded`; a fresh failure leaves
the instance in `:starting`/`:running`.
```

The platform UI has no stop/start update copy to change: the only restart
notes are the storage-growth lines in `instance_live/show.ex`
(`A restart may be needed to see the new space.`), which are unrelated to
the env roll. The "instance card" is the provider's registry resource page
(Slice 4).

**Done when**

```sh
cd /home/terence/Work/FluxVale/fv776-restart
rg -n 'quota cannot fit a second pod|stop it \(`running = false`\)' docs apps \
  -g '!docs/plans/776-instance-restart-strategy.md'
```

Expected: no output (the plan itself quotes the workaround it retires).

## Slice 4 — provider repo follow-up

Separate PR in `fluxvale/terraform-provider-fluxvale`, after the platform
fix ships (or in parallel with `Refs` on the platform issue). Exact
locations verified on `main`:

- `docs/resources/instance.md` line 58 — the instance card's update copy.
  Replace the stop/start workaround with: "The platform rolls a running
  instance after an env change — the old pod goes down before the new one
  starts (a short restart), with no stop/start needed."
- `docs/guides/secrets.md` lines 151–153 — delete the stop-first
  paragraph ("If the app's resource quota cannot accommodate a second pod
  ...").
- `docs/guides/compatibility.md` lines 57–60 — delete the "needs room for
  a second pod" paragraph.
- `examples/owner-stack/README.md` lines 131–133 — delete "If the app's
  quota cannot fit a second pod ...".
- `internal/provider/acceptance_secret_env_test.go` — the second step
  currently stops (`running = false`), rotates, then starts. Change it to
  rotate while running (`running = true`, `secret_env_vars_version = 2`),
  and assert the app reports the changed flags after the in-place roll.
  Keep a stopped step only if the removal path needs it for a non-quota
  reason; the stop/start-as-workaround comment must go.

**Done when**

```sh
# in terraform-provider-fluxvale
rg -n 'stop it first|cannot accommodate a second pod|needs room for a second pod|quota cannot fit' docs examples internal
```

Expected: no output except the acceptance test's intentional
stopped-state step, if one remains.

## Slice 5 — staging proof (after the platform fix deploys)

Preconditions: the merge is live on staging (`/health` version =
`sha-<merge>`) and a staging PAT with `instances:read` +
`instances:write` is available. Never print the token. Use a **healthy
running** staging instance: the incident instance
(`01a1d745-7bc4-758c-84d7-2819075f75e9`, `stg-thrumming-hill-9288`) is
`:error` evidence, not the proof target — recovering it is a separate
check (its Deployment still carries a deadlined `Progressing` condition
until a new revision lands, which would muddy the roll assertion).

```sh
export BASE=https://staging.fluxvale.com
export PAT='<staging PAT>'
export ID='<a running staging instance id>'      # from GET /api/v1/instances
export SLUG='<that instance slug>'
export NS=fluxvale-app-$ID
api() { curl -fsS -H "Authorization: Bearer $PAT" -H 'content-type: application/vnd.api+json' "$@"; }
# Event OBJECTS can stay constant while an Event repeats (count/series.count
# grows), so count occurrences, never `.items|length`.
failed_create_occurrences() {
  kubectl --context admin@fluxvale -n "$NS" get events \
    --field-selector reason=FailedCreate -o json \
    | jq '[.items[] | (.series.count // .count // 1)] | add // 0'
}

curl -fsS "$BASE/health" | jq -r .version
# sha-<merge>

# 1. the instance starts running
api "$BASE/api/v1/instances/$ID" | jq -r '.data.attributes.status'
# running

# 2. baseline occurrences (the namespace may carry old events)
BEFORE=$(failed_create_occurrences)
echo "before=$BEFORE"

# 3. roll a running instance's env
START=$(date -u +%FT%TZ)
api -X PATCH "$BASE/api/v1/instances/$ID/env" \
  -d '{"data":{"type":"instance","id":"'"$ID"'","attributes":{"set":{"FLUXVALE_ROLL_PROOF":"'"$START"'"}}}}' \
  | jq -r .data.attributes.status
# running (the row does not leave running for a live roll)

# 4. immediately after the PATCH, the restart path has normalized the
#    existing Deployment's strategy; the rollout uses it
kubectl --context admin@fluxvale -n "$NS" get deploy app \
  -o jsonpath='{.spec.strategy.type}{" "}{.spec.strategy.rollingUpdate.maxSurge}{" "}{.spec.strategy.rollingUpdate.maxUnavailable}{"\n"}'
# RollingUpdate 0 1

# 5. watch the row through a reconcile cycle
for i in $(seq 1 18); do api "$BASE/api/v1/instances/$ID" | jq -r .data.attributes.status; sleep 5; done \
  | sort | uniq -c
# 18 running   (no error)

# 6. wait for the Deployment, then the app's readiness
kubectl --context admin@fluxvale -n "$NS" rollout status deploy/app --timeout=300s
# deployment "app" successfully rolled out
curl -fsS -o /dev/null -w '%{http_code}\n' "https://$SLUG.fluxvale.app/"
# 200

# 7. settle: no lingering failure condition
kubectl --context admin@fluxvale -n "$NS" get deploy app \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason}{"\n"}{end}'
# Progressing=True/NewReplicaSetAvailable
# Available=True/MinimumReplicasAvailable
# (no ReplicaFailure line)

# 8. quota events: the handoff burst must stop, not grow
AFTER=$(failed_create_occurrences)
sleep 30
AFTER2=$(failed_create_occurrences)
echo "before=$BEFORE after=$AFTER after30=$AFTER2"
# D1=A (maxSurge 0): after > before (the ~1s handoff burst), after30 == after
#   (no sustained failures), and step 7 shows no ReplicaFailure.
# D1=B (Recreate): after == before, after30 == before (zero new events).
```

The incident instance remains `:error` evidence (its old pod still
serves 200). It can be recovered separately with `PATCH /deploy`, but it
is not the proof target: its Deployment's deadlined `Progressing`
condition persists until a new revision lands, which would muddy the roll
assertion.

**Done when**: the transcript above is in the PR/issue report with the
raw occurrence counts (`before`, `after`, `after30` — not Event object
counts), 18 × `running`, `200`, the condition list, and D1's chosen
assertion holds.

## Overall PR gate

```sh
cd /home/terence/Work/FluxVale/fv776-restart/apps/platform
mix ci
```

Expected: every alias step passes — `format --check-formatted`,
`compile --warnings-as-errors`, `gettext.extract --check-up-to-date`,
`blog.lint`, `docs.lint`, `ash.codegen --check`, `credo --strict`,
`dialyzer`, `coveralls.json` at 100%.

PR title: `fix(platform): roll instance updates within the one-pod quota`.
`Closes #776` only if the provider follow-up is tracked separately;
otherwise `Refs #776` and close after Slice 4. No reviewer/assignee.

## Verification status

- Slices 1–3 implemented; `mix ci` and the Rust gates are the PR gate.
- `no_capacity` and stuck-`:error` recovery ride the same status machine,
  InstanceStatus copy, PromEx pair set, and OpenAPI artifact.
- Slice 5 (staging env-roll proof) runs after the fix is live on staging;
  it is not part of this PR's merge gate.
- Slice 4 (provider repo) remains a separate PR — this PR closes #776 on
  the platform behaviour it owns.
