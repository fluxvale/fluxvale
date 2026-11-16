# Plan: per-PR review environments (#798)

Status: **PROPOSED — gate**. No build until Terence's go. On go this
branch also appends `ADR-0024` Amendment 3 (the decisions below) and
updates the ADR index.

Issue: [#798](https://github.com/fluxvale/fluxvale/issues/798) —
"Every pull request gets its own deployed stack to click through before
merge, on the staging cluster." Measured correction: there is no
separate staging cluster; staging is a namespace on the one Talos box
([ADR-0010](../adr/00010-staging-namespace-flag-gated.md)).

Decision record: [ADR-0024](../adr/00024-e2e-review-environments.md)
(Am. 1–2 accepted: review envs are infra, provisioned from the fleet
repo). This plan fills the implementation gaps Am. 2 left open and
supersedes the parts the box measurement disproved.

## The shape in one paragraph

One namespace per PR (`fluxvale-pr-<n>`) on the shared box, holding the
PR's own image (reused from the PR CI build, pinned by digest), a
per-env database + role on the existing CNPG cluster, generated secrets,
a quota, and a route at `pr-<n>.review.fluxvale.app`. The fleet repo's
workflow provisions and tears it down on dispatch from app CI; a
scheduled janitor enforces a 7-day maximum lifetime and a 3-env cap.
The platform inside keeps its real instance-provisioning behavior, with
one new admission boundary (a ValidatingAdmissionPolicy) so PR code
cannot touch another env's namespaces. The PR check proves the exact
commit is deployed and serving; the human click-through stays human.

## What is actually on the box (measured 2026-11-16, not assumed)

| Fact | Measured |
|---|---|
| Node | 1× Talos `nuremberg-01`, 8 vCPU / 16 GB; allocatable 7,950m / 15.0 GiB |
| Scheduled requests | **4,375m (55%) CPU, 6,916 Mi (45%) RAM**; limits 132% / 132% |
| Pods | 43; **33 `fluxvale-app-*` namespaces, only 5 with a running instance pod** (the rest stopped/sleeping) |
| Disk | 331 Gi in PVCs of ~490 Gi allocatable (≈159 Gi free) |
| Postgres | one CNPG cluster (1 instance, 20 Gi, no requests/limits, pooler transaction mode); 5 tenant DBs, ~140 MB total |
| Staging / prod | 2 pods each (platform 100m/256Mi request, 1 Gi limit; MCP 100m/128Mi); **staging has no ResourceQuota** despite ADR-0010's "tight quota" |
| Also on the box | thalmyra prod+staging, pursecraft prod, access gateways, monitoring, Flux, cert-manager, Traefik |
| Box COGS | €21.61/mo ([ADR-0028](../adr/00028-flat-rate-pricing.md) calibration basis) |

Findings that change the plan:

- **ADR-0024's `INSTANCE_NAMESPACE_PREFIX=fluxvale-pr-<n>-app-` does not
  exist.** Instance namespaces are always `fluxvale-app-<uuid>`; the
  only cross-env isolation is the `fluxvale.io/platform-env` label
  ([ADR-0005](../adr/00005-customer-instances-as-namespaces.md) Am. 2).
  Review envs must therefore use a unique `PLATFORM_ENV=review-<n>`;
  a shared `review` value would re-open the #196 cross-env deletion.
- **`kubectl` says CNPG ships `Database` and `DatabaseRole` CRDs**, so a
  per-env database is declarative — no psql admin job, no superuser.
- **ValidatingAdmissionPolicy is enabled** (v1.37): namespace/RoleBinding
  containment is expressible without the RBAC pattern restriction
  ADR-0024 correctly called impossible.
- **The app is partly pre-wired for review**: the noindex plug already
  names `pr-*.review.*`; the demo-board gate allowlists exactly
  `staging|review|local` (so `review-<n>` needs a one-line extension);
  `PLATFORM_ENV` is required and label-validated in prod.
- **TestInbox reads are platform-admin only** and the e2e helper holds an
  admin PAT. A human has no first code, so a review env with no Postmark
  key is unclickable until the inbox opens on review only.
- **CI already builds a PR image without pushing** (`platform-image`);
  `deploy-image` pushes only on main. The PR image is one `push: true`
  away — never rebuild in the fleet repo.
- **The ruleset requires two contexts: `CodeRabbit` and `Wait for CI`**
  (0 approvals, squash only). The review check should join the
  umbrella, not the ruleset.

## Decisions

### D1 — Namespace: one `fluxvale-pr-<n>` per PR; instances keep product namespaces

`fluxvale-pr-<n>` holds the platform Deployment, Service, SA, route,
quota, and the per-env Secret. The platform's own instance namespaces
are **unchanged** (`fluxvale-app-<uuid>`, label
`fluxvale.io/platform-env=review-<n>`), so the product's deploy path is
reviewed as it ships. The review namespace carries the janitor's
identity:

```
labels:      app.kubernetes.io/part-of=fluxvale, fluxvale.io/review=pr-<n>
annotations: fluxvale.io/review-pr, fluxvale.io/review-sha,
             fluxvale.io/review-updated-at, fluxvale.io/review-expires-at
```

The namespace itself gets no `platform-env` label (it is not an
instance namespace). Teardown selects both sets by their labels.

Review-env instances are **ordinary instances**: scale-to-zero
([ADR-0036](../adr/00036-scale-to-zero-wake-on-use.md)), the per-instance
ResourceQuota (the live `app-quota`), allocation-based sizing/pricing
([ADR-0028](../adr/00028-flat-rate-pricing.md),
[ADR-0043](../adr/00043-instance-resize.md)) apply untouched. Nothing new
is built for density — the env is the platform's own machinery under one
more env label.

Rejected: a shared `fluxvale-review` namespace (one quota, one teardown,
one bad migration kills every env; no per-PR RBAC); name-prefixed
instance namespaces (product code change for a cosmetic gain, and RBAC
still cannot pattern-restrict).

### D2 — Postgres: per-env database + role on the shared CNPG cluster

One `Database` + `DatabaseRole` per env in `fluxvale-db`, applied by the
provisioner:

```yaml
DatabaseRole: {name: review_pr_<n>, cluster: fluxvale-cnpg, login: true,
               connectionLimit: 20, passwordSecret: {name: review-pr-<n>-db},
               databaseRoleReclaimPolicy: delete}
Database:     {name: review_pr_<n>, cluster: fluxvale-cnpg, owner: review_pr_<n>,
               connectionLimit: 20, databaseReclaimPolicy: delete}
```

The app connects through the existing pooler
(`fluxvale-cnpg-pooler.fluxvale-db.svc:5432`) with a generated password.
The role is not superuser and not `CREATEDB`; the database is its own
boundary. Teardown order: namespace (pods gone) → `Database` (drops the
DB) → `DatabaseRole` → secrets.

Rejected: **schema per env** — [ADR-0009](../adr/00009-single-cnpg-cluster.md)
forbids shared schemas (weaker boundary; search_path is a connection
detail, not an ownership boundary), and Ash migrations assume one
schema. Rejected: **a disposable Postgres pod per env** (ADR-0024's
original shape) — 1 GB + 10 Gi per env for a database the shared cluster
already serves; the scratch-cluster path stays for restore/upgrade
drills. Accepted blast radius: disk/WAL/connections are shared; bounded
by the role's connection limit, the 3-env cap, and the fact that review
DBs are ~100 MB. CNPG backups are cluster-wide, so review DBs ride R2
retention for up to 30 days — accepted (seed data only).

### D3 — Image: reuse the PR CI build; dispatch the digest

`platform-image` (existing PR job) gains `packages: write`, a
same-repo-only `push: true`, tags `pr-<n>-<sha>`, and a digest output.
The review-env job dispatches `{pr, sha, digest}`; the fleet overlay
pins `image: ghcr.io/fluxvale/fluxvale@sha256:…` — never a tag, so a
stale `pr-<n>` tag cannot deploy. Fork PRs get no push (GITHUB_TOKEN is
read-only there) and no review env; they are reviewed on staging.
GHCR storage for public packages is free; retention is optional.

Rejected: building in the fleet repo (no source, wrong credential
boundary); deploying `sha-<sha>` (that tag exists only for main).

### D4 — Hostname: one wildcard, one SAN, default TLS store

- Platform: `pr-<n>.review.fluxvale.app`
- Instances: `INSTANCES_BASE_DOMAIN=review.fluxvale.app` +
  `INSTANCES_SLUG_PREFIX=pr<n>` → `pr<n>-<slug>.review.fluxvale.app`
- Optional MCP later: `mcp-pr-<n>.review.fluxvale.app`

Both are one label under `review`, so a single
`*.review.fluxvale.app` covers everything. TLS: add
`*.review.fluxvale.app` as a second SAN on the **existing**
`wildcard-fluxvale-app` Certificate (the default TLSStore already serves
it); review IngressRoutes set `tls: {}` and no `secretName`. One manual
prerequisite: the `*.review.fluxvale.app` DNS record at the edge (fleet
runbook, private).

Rejected: a second Certificate + TLSStore (one default store only, and
secrets are namespace-scoped, so every review namespace would need a
copied cert); per-env Certificates (Let's Encrypt's 5-per-week duplicate
limit for identical SAN sets — three pushes a week would trip it).
Accepted coupling: a failed renewal now affects instance TLS too; the
existing expiry alert covers it.

### D5 — Secrets: generated per env, no external store, no production data

The provisioner generates `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`, and
the DB password (`openssl rand`), applies them as one Secret in the
review namespace (+ the DB copy in `fluxvale-db`), and never logs them.
No 1Password/BWS items are rendered into a review namespace. Not set:
Postmark, Polar, HitPay, PostHog, Google OIDC, S3 backups, metrics
token. `TEST_INBOX_ENABLED=true` + `TEST_INBOX_OPEN=true` (D6); mail
never leaves the box. `ADMIN_MOUNT_KEY` unset (the `/admin` mount 404s;
platform-admin authority still works through normal sign-in).
`PROMEX_ENABLED=false`, no OTLP endpoint.

Data: seeds only (`bin/seed` + `bin/ensure-cluster`) plus whatever the
reviewer creates. No production DB dump, no production credentials, no
customer data. The only shared surfaces — the node, the CNPG cluster,
the edge, public GHCR — carry no production secret.

### D6 — Human access: open the TestInbox on review environments only

New `TEST_INBOX_OPEN=true` makes the TestInbox read routes answer
without credentials (the Swoosh Local store already holds every code
when no Postmark key is set). A reviewer signs in as
`admin@fluxvale.com` (seeded), reads the code at
`/test-inbox/api/mails/latest?email=admin@fluxvale.com`, and clicks
through. This is account takeover of a **disposable, seed-only,
noindexed** environment — accepted; the alternative (a staging Postmark
token in a PR-controlled pod) is a real secret in the wrong place, and
the admin-PAT path has a chicken-and-egg first login.

### D7 — Lifecycle and caps

- **Provision**: app CI on `pull_request` [opened, reopened,
  synchronize, ready_for_review], skipped for drafts, forks, and
  non-platform changes (`check-changes`). Dispatch
  `review-env` → fleet workflow → apply → app job polls
  `/health` until `version == head SHA`, then `/health/ready`, then
  comments the URL + sign-in recipe.
- **Teardown**: `pull_request: closed` (merge or close) dispatches
  `review-env-teardown`; the app job is fire-and-forget.
- **Janitor**: fleet workflow every 6 h (private-repo minutes: ~120/mo)
  deletes envs whose `fluxvale.io/review-expires-at` is past; best-effort
  PR-state check. TTL is **7 days after the last push** (refreshed on
  every update), so long-lived active PRs keep an env and abandoned ones
  do not.
- **Concurrency cap: 3.** A 4th provision evicts the least-recently-
  updated env (teardown + comment on that PR) before applying.
- **Instance count inside an env is not hard-capped by Kubernetes**
  (instance namespaces carry their own per-allocation quotas). The
  PR comment asks for one instance; the scheduler is the backstop
  (Pending, not eviction). Node request pressure is the ADR-0016
  node-#2 trigger.

### D8 — Merge checklist: `review-env` joins `Wait for CI`

Today the ruleset requires `CodeRabbit` + `Wait for CI`, 0 approvals.
The new `review-env` job joins `wait-for-ci.needs`; the ruleset does not
change. Green means: **the PR's exact digest is deployed at
`pr-<n>.review.fluxvale.app`, `/health.version` equals the head SHA,
`/health/ready` is 200, and the landing page is 200.** It does not mean
a human clicked; that remains the maintainer's review. Skipped = draft,
fork, or nothing that fires the platform filter. Red = the PR does not
boot as deployed; fix it, or admin-merge with a note only when the
failure is proven infra (box down), never to bypass the PR.

Rejected: a required human approval (the maintainer authors most PRs;
GitHub forbids self-approval) and a separate required context (the
umbrella already exists so path-skipped jobs cannot strand a PR).

### D9 — Containment: one ValidatingAdmissionPolicy before any instance RBAC

The review platform's SA is bound to the existing `fluxvale-platform`
ClusterRole (it needs namespace lifecycle to dogfood instance deploy).
RBAC cannot pattern-restrict, so two small cluster-scoped policies
(namespaces; rolebindings) deny, for SAs named
`system:serviceaccount:fluxvale-pr-*`:

- namespace CREATE/UPDATE/DELETE unless the namespace is named
  `fluxvale-app-*` **and** labeled
  `fluxvale.io/platform-env=review-<n>` (derived from the SA's own
  namespace name);
- `rolebindings` CREATE/UPDATE/DELETE unless the target namespace
  (`namespaceObject`) carries the same env label.

That turns "PR code may delete any namespace" into "PR code may only
touch its own". Reads stay cluster-wide (names/labels only, no secrets);
accepted. Without this policy, review envs get **no** cluster RBAC and
cannot create instances — do not ship D9 and the binding in the same
breath; the policy lands first.

## Cost model

Box: €21.61/mo over 7.95 vCPU / 15.0 GiB allocatable = **€2.72 per
core-month, €1.44 per GiB-month**. The reference sellable allocation is
`micro` = 0.25 CPU / 512 MB = **$2.59/mo**
([pricing calibration](../pricing-calibration.md)).

Per review env (v1, one micro instance inside):

| Item | Request | €/mo at 24/7 | Sellable equivalent |
|---|---|---|---|
| Platform app | 250m / 512Mi | €1.40 | $2.59 |
| One instance | 250m / 512Mi | €1.40 | $2.59 |
| **Per env** | **500m / 1 GiB** | **€2.80** | **$5.18** |
| **3 envs (cap)** | **1.5 CPU / 3 GiB** | **€8.40** | **$15.54** |

Worst case, N = 3 simultaneous:

- Requests: 1.5 CPU (42% of the free 3.575) and 3 GiB (36% of the free
  8.25). With a review-local MCP (+100m/128Mi per env) it is 1.8 CPU /
  3.4 GiB (50% / 41%).
- Limits: 4.5 CPU / 6 GiB added → node totals 189% CPU / 173% memory
  limits (burst overcommit; today is already 132%). Requests are the
  scheduling constraint and they fit.
- Disk: 30 Gi of instance PVCs (159 Gi free); DBs ~300 MB + WAL.
- Cash: €8.40/mo only if all three run 24/7; a 7-day TTL and normal PR
  lifetimes land under €2/mo. App CI minutes are free (public repo); the
  fleet's private-repo runs add ~1–3 min per push plus ~120 min/mo of
  janitor — comfortably inside the 2,000-minute free tier.
- The honest cost is **capacity**: 3 envs occupy 6 `micro` slots of
  sellable density ($15.54/mo). That is the number to weigh, not the
  €8.40.

Trigger: a 4th concurrent env, or node requests > 80%, is
[ADR-0016](../adr/00016-deferred-triggers.md)'s named node-#2 trigger
("review-env capacity"). The plan does not pre-buy it.

## Slice plan

Each slice is independently shippable, with its own branch/worktree and
its own `Done when`. App slices run with
`MIX_TEST_PARTITION=rv798-<slice>` on **every** `mix test`/`mix ci`
(#241: lanes share `flux_vale_test`). Fleet slices live in
`fluxvale/infrastructure` (private); the fleet's committed identity is
used, no invented author.

Order: S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8. S4 can be exercised with a
main image and a fake PR number before S3 is live; S6 must be applied
before the first env that gets instance RBAC.

### S0 — This plan + ADR-0024 Amendment 3 (this branch)

**Context**: the gate artifact. On go, append the amendment (D1–D9),
update the ADR index line to `Accepted (amended — see Amendments 1–3)`,
and open the docs PR referencing #798 without `Closes` (the umbrella
stays open until S8).

**Files**: `docs/plans/798-review-environments.md`,
`docs/adr/00024-e2e-review-environments.md`, `docs/adr/README.md`.

**Done when**: `mix ci` is not needed (docs-only PR); the PR body links
the plan; a maintainer reads it and says go.

### S1 — `review-<n>` is a non-prod platform env

**Context**: `PLATFORM_ENV` is required in prod and label-validated; the
demo-board gate allowlists exactly `staging|review|local`. A review env
must use a unique `review-<n>` (D1) or two review envs share a sweep
scope, so the gate must accept the prefix.

**Files**: `apps/platform/config/runtime.exs` (the demo-seed gate near
line 628), `apps/platform/lib/flux_vale/seeds.ex` (the moduledoc that
currently claims "anything but production"), `apps/platform/test/flux_vale/required_envs_test.exs`.

**Steps**:

1. Replace the allowlist with: non-production when the value is
   `"staging"` or `"local"`, or starts with `"review-"` or equals
   `"review"`. Keep the "typo stays empty" posture: `"reviewer"` and
   `"prod"` must not seed.
2. Fix the seeds moduledoc to state the real rule.
3. Add three test arms: `review-798` seeds; bare `review` seeds;
   `reviewer` does not.

**Done when**:

```sh
cd apps/platform
MIX_TEST_PARTITION=rv798-s1 mix test test/flux_vale/required_envs_test.exs
MIX_TEST_PARTITION=rv798-s1 mix ci
```

green, and no other behaviour changes.

### S2 — Open TestInbox reads on review environments only

**Context**: a review env has no Postmark key, so every sign-in code
lands in Swoosh Local; the read routes are admin-gated, so a human
cannot get the first code (D6). The surface is already 404-gated by
`TestInboxEnabled` and disabled globally in prod.

**Files**: `apps/platform/lib/flux_vale/test_inbox.ex` (`open?/0`),
`apps/platform/config/runtime.exs` (the `TEST_INBOX_ENABLED` block),
`apps/platform/lib/flux_vale_web/plugs/test_inbox_access.ex` (new),
`apps/platform/lib/flux_vale_web/router.ex` (the two `/test-inbox`
pipelines), `apps/platform/test/flux_vale/test_inbox_test.exs`,
`apps/platform/test/flux_vale_web/test_inbox_gate_test.exs`,
`apps/platform/test/flux_vale_web/test_inbox_route_test.exs`.

**Steps**:

1. `TestInbox.open?/0` reads `:test_inbox, open: true`; runtime sets it
   only when `TEST_INBOX_OPEN` is `"true"`/`"1"` (value-gated, like
   `TEST_INBOX_ENABLED`).
2. New plug `TestInboxAccess`: when `open?`, pass; otherwise delegate to
   `FluxValeWeb.Plugs.RequirePlatformAdmin` with the pipeline's format.
   Replace that plug in both pipelines (keep `Authenticate`, so a
   signed-in non-admin is still refused when closed).
3. Tests: open + no credentials → 200 on
   `/test-inbox/api/mails/latest`; open + `enabled: false` → 404 (the
   disabled gate still wins); open unset → 401/403; `/admin` unaffected.

**Done when**:

```sh
cd apps/platform
MIX_TEST_PARTITION=rv798-s2 mix test test/flux_vale/test_inbox_test.exs \
  test/flux_vale_web/test_inbox_gate_test.exs \
  test/flux_vale_web/test_inbox_route_test.exs
MIX_TEST_PARTITION=rv798-s2 mix ci
```

green.

### S3 — Wildcard SAN for `*.review.fluxvale.app`

**Context**: `pr-<n>.review.fluxvale.app` is two levels deep;
`*.fluxvale.app` does not cover it (D4). The default TLSStore already
serves the existing wildcard, so one SAN is the whole change. A manual
DNS record (`*.review` → the edge) is a prerequisite, documented in the
fleet runbook.

**Files**: `cluster/traefik/crs/certificate.yaml`,
`DEPLOYMENT.md` (fleet repo: the DNS step + verification).

**Steps**:

1. Add `"*.review.fluxvale.app"` to `spec.dnsNames`; comment the
   renewal coupling.
2. Add the DNS record (Cloudflare, same zone as the existing wildcard).
3. Let Flux reconcile; cert-manager reissues via DNS-01.

**Done when**:

```sh
kubectl kustomize cluster/traefik/crs | grep 'review.fluxvale.app'
kubectl -n traefik get certificate wildcard-fluxvale-app \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'          # True
openssl s_client -connect pr-1.review.fluxvale.app:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
```

lists both `*.fluxvale.app` and `*.review.fluxvale.app`. A request to
`https://pr-1.review.fluxvale.app/health` completes TLS (Traefik 404s
until S4).

### S4 — Provision and tear down a PR environment

**Context**: the fleet repo provisions review envs (ADR-0024 Am. 2).
The overlay is `apps/base` + a review patch; the namespace name and
image are dynamic, so the workflow renders a temp overlay and applies
it. No instance RBAC yet (S6 adds it; without it, instance create fails
loudly and safely).

**Files** (fleet repo): `apps/review/overlay/kustomization.yaml`
(the patch set), `scripts/review/render.sh`,
`scripts/review/provision.sh`, `scripts/review/teardown.sh`,
`scripts/review/lib.sh`, `.github/workflows/review-env.yaml`,
`cluster/review-provisioner.yaml` (SA + ClusterRole + binding for the
workflow's kubeconfig), `DEPLOYMENT.md`.

**Contract** (what the scripts implement):

- Env: `PLATFORM_ENV=review-<n>`, `PHX_HOST=pr-<n>.review.fluxvale.app`,
  `INSTANCES_BASE_DOMAIN=review.fluxvale.app`,
  `INSTANCES_SLUG_PREFIX=pr<n>`,
  `INSTANCE_RBAC_SA_NAMESPACE=fluxvale-pr-<n>`,
  `ACCESS_GATEWAY_NAMESPACE=fluxvale-pr-<n>`,
  `DB_HOST=fluxvale-cnpg-pooler.fluxvale-db.svc.cluster.local`,
  `DB_NAME=review_pr_<n>`, `DB_USER=review_pr_<n>`,
  `CLUSTER_NAME=nuremberg-01`, `TEST_INBOX_ENABLED=true`,
  `TEST_INBOX_OPEN=true`, `PROMEX_ENABLED=false`,
  `MCP_SERVER_URL=https://mcp.fluxvale.com/mcp` (documented limitation:
  no review-local MCP in v1).
- Resources: request 250m/512Mi, limit 1 CPU/1Gi; quota
  `requests.cpu=1, requests.memory=2Gi, limits.cpu=2, limits.memory=4Gi,
  pods=10, persistentvolumeclaims=4, requests.storage=40Gi`.
- Secrets: `review-env-secrets` (SECRET_KEY_BASE, TOKEN_SIGNING_SECRET)
  and `review-pr-<n>-db` (basic-auth, also in `fluxvale-db`).
- Service annotation `prometheus.io/scrape=false` (no metrics token in
  a review env; keep the prod Alloy scrape off it).
- CNPG: `DatabaseRole` first, wait Ready, then `Database`; both with
  reclaim policy `delete`.
- Namespace: labels/annotations from D1;
  `fluxvale.io/review-expires-at` = now + 7 days (refreshed on each
  provision).
- Route: reuse `apps/base/ingressroute.yaml`, patch Host and
  `tls: {}` (default store).
- Cap: count `-l fluxvale.io/review`; at 3, tear down the oldest
  `fluxvale.io/review-updated-at` and comment on that PR (the fleet
  secret `REVIEW_APP_TOKEN`, fine-grained to `fluxvale/fluxvale`
  `pull-requests: write`; used only for that comment).
- Credentials: a `review-provisioner` SA (namespaces, secrets,
  `databases`/`databaseroles` in `fluxvale-db`, clusterrolebindings —
  nothing else) plus a long-lived token Secret, stored as
  `REVIEW_ENV_KUBECONFIG` in the fleet repo; 90-day rotation noted in
  the runbook.
- Payload validation: `pr` is an integer, `image` matches
  `^ghcr\.io/fluxvale/fluxvale@sha256:[0-9a-f]{64}$`, and
  `REVIEW_APP_TOKEN` confirms the PR's head SHA equals `sha`; anything
  else fails before touching the cluster.
- The DB drop can race the pooler's pooled connections; the operator
  retries and teardown is idempotent.
- Idempotent: re-running for the same PR updates the image and
  `review-sha`, leaves the DB alone.
- Teardown: delete the review namespace (its Secret goes with it), then
  every namespace labeled `fluxvale.io/platform-env=review-<n>`, the
  CNPG CRs, the DB password Secret in `fluxvale-db`, and the
  ClusterRoleBinding if present.

**Workflow**: `repository_dispatch` types `review-env` and
`review-env-teardown`; `concurrency: review-env-${{ client_payload.pr }}`
with `cancel-in-progress: true`; a manual `workflow_dispatch`
(`action: provision|teardown`, `pr`, `sha`, `image`) for the smoke test.
Add `cluster/review-provisioner.yaml` to `cluster/kustomization.yaml`
(Flux owns it). The app-side job owns the PR comment and the check; the
fleet owns the cluster.

**Done when** (manual, against a main `sha-<sha>` image and `pr=999`):

```sh
gh workflow run review-env.yaml -f pr=999 -f sha=<sha> -f image=ghcr.io/fluxvale/fluxvale:sha-<sha>
curl -fsS https://pr-999.review.fluxvale.app/health | jq -e --arg s <sha> '.version == $s'
curl -fsS -o /dev/null -w '%{http_code}\n' https://pr-999.review.fluxvale.app/health/ready   # 200
kubectl -n fluxvale-pr-999 get deploy fluxvale-platform -o jsonpath='{.status.readyReplicas}' # 1
kubectl -n fluxvale-db exec fluxvale-cnpg-1 -- psql -U postgres -Atc \
  "select 1 from pg_database where datname='review_pr_999'"                                   # 1
gh workflow run review-env.yaml -f action=teardown -f pr=999
kubectl get ns -l fluxvale.io/review            # empty
```

and a new dispatch for a different sha updates the env in place.

### S5 — App CI: per-PR image push, the check, and teardown dispatch

**Context**: D3/D7/D8. The PR image already builds (`platform-image`,
`push: false`); this slice pushes it for same-repo branches, dispatches
the fleet workflow, waits for the exact SHA, and joins the umbrella
check. No cluster credential enters this repo — the strongest one is
"may dispatch to the fleet repo" (ADR-0024 Am. 2).

**Files**: `.github/workflows/ci.yml`
(`platform-image`, a new `review-env` job, `wait-for-ci.needs`),
`.github/workflows/review-env-teardown.yml` (new).

**Steps**:

0. Add `types: [opened, synchronize, reopened, ready_for_review]` to
   `ci.yml`'s `pull_request` trigger (the default omits
   `ready_for_review`, so a draft→ready transition would never
   provision), and `types: [closed]` to the teardown workflow (the
   default omits `closed`).
1. `platform-image`: `permissions: contents: read, packages: write`;
   `id: build`; `push: ${{ github.event.pull_request.head.repo.full_name == github.repository }}`;
   tags `ghcr.io/fluxvale/fluxvale:pr-<n>-<sha>` (same manifest, one
   per PR push); `outputs.digest: ${{ steps.build.outputs.digest }}`.
   Fork PRs keep `push: false` and their read-only token.
2. New `review-env` job: `needs: [check-changes, platform,
   platform-image]`; `if:` PR, `platform == 'true'`, same-repo head,
   not draft; `permissions: contents: read, pull-requests: write`;
   concurrency inherits the workflow's `ci-<ref>` group.
   - Dispatch `POST /repos/fluxvale/infrastructure/dispatches`
     (`event_type: review-env`, payload `{pr, sha, digest}`) with a
     fine-grained PAT (`REVIEW_ENV_DISPATCH_TOKEN`, contents: write on
     the fleet repo only).
   - Poll `https://pr-<n>.review.fluxvale.app/health` every 10 s for up
     to 10 min until `version == github.sha`; then require `/health/ready`
     200 and `/` 200.
   - Comment the URL and the sign-in recipe (`admin@fluxvale.com`; code
     at `/test-inbox/api/mails/latest?email=admin@fluxvale.com`), or the
     failure + the fleet run link.
3. New teardown workflow: on `pull_request: closed`, dispatch
   `review-env-teardown` with `{pr}` (skip forks; no cluster creds).
4. Add `review-env` to `wait-for-ci.needs`; the ruleset is unchanged
   ("Wait for CI" is the required context).

**Done when** (on a real same-repo platform PR):

```sh
gh pr checks <n>                                  # review-env pass
gh pr view <n> --comments | grep 'review.fluxvale.app'
docker manifest inspect ghcr.io/fluxvale/fluxvale:pr-<n>-<sha> >/dev/null
```

the comment URL serves the head SHA, a fork PR's `review-env` is
skipped with no push, a re-run on the same SHA stays green, and closing
the PR makes the URL 404 after the teardown run. No `mix test` in this
slice.

### S6 — Containment: VAP + instance RBAC (the safety gate)

**Context**: the review platform must dogfood instance deploy, which
means binding `fluxvale-platform` (namespace create/delete cluster-wide).
PR code is then arbitrary code with that role. RBAC cannot
pattern-restrict (ADR-0024), but VAP can (D9). **Do not bind the role
before the policy is live.**

**Files** (fleet repo): `cluster/review-containment.yaml`
(two ValidatingAdmissionPolicies + bindings),
`scripts/review/containment-test.sh`, `scripts/review/provision.sh` (add
the per-env ClusterRoleBinding), `cluster/kustomization.yaml`.

**Policy** (two static policies, no per-env params; the env is derived
from the SA's own namespace):

```yaml
# both policies share the same matchConditions
matchConditions:
  - name: review-sa
    expression: request.userInfo.username.startsWith('system:serviceaccount:fluxvale-pr-')

# policy A — apiGroups: [""], resources: ["namespaces"], ops CREATE/UPDATE/DELETE
validations:
  - expression: |
      request.operation == 'CREATE'
        ? (object.metadata.name.startsWith('fluxvale-app-') &&
           object.metadata.labels['fluxvale.io/platform-env'] ==
             request.userInfo.username.split(':')[2].replace('fluxvale-pr-', 'review-'))
        : request.operation == 'DELETE'
          ? (oldObject.metadata.name.startsWith('fluxvale-app-') &&
             oldObject.metadata.labels['fluxvale.io/platform-env'] ==
               request.userInfo.username.split(':')[2].replace('fluxvale-pr-', 'review-'))
          : (object.metadata.name.startsWith('fluxvale-app-') &&
             object.metadata.labels['fluxvale.io/platform-env'] ==
               request.userInfo.username.split(':')[2].replace('fluxvale-pr-', 'review-') &&
             oldObject.metadata.labels['fluxvale.io/platform-env'] ==
               request.userInfo.username.split(':')[2].replace('fluxvale-pr-', 'review-'))

# policy B — apiGroups: ["rbac.authorization.k8s.io"],
#            resources: ["rolebindings"], ops CREATE/UPDATE/DELETE
validations:
  - expression: |
      namespaceObject.metadata.labels['fluxvale.io/platform-env'] ==
        request.userInfo.username.split(':')[2].replace('fluxvale-pr-', 'review-')
```

If the CEL string extension rejects `replace`, use a binding `paramRef`
with `{env: review-<n>}` per env instead (one extra object per env).

**Per-env binding**: `ClusterRoleBinding
fluxvale-platform-review-<n>` → existing `fluxvale-platform`
ClusterRole, subject `fluxvale-pr-<n>/fluxvale-platform`.

**Test** (`containment-test.sh`, run on k3d per ADR-0020): create a fake
SA in `fluxvale-pr-798`, namespaces `fluxvale-app-<uuid>` labeled
`review-798` and one labeled `production`; run six `kubectl --as=…`
mutations:

1. delete own-labelled namespace → allowed
2. delete production-labelled namespace → **denied**
3. create `fluxvale-app-<uuid>` + `review-798` label → allowed
4. create a namespace labelled `production` → **denied**
5. create a RoleBinding in the own namespace → allowed
6. create a RoleBinding in the production namespace → **denied**

**Done when**: the six PASS lines on k3d; the policy + binding applied
to the box (`kubectl get validatingadmissionpolicy review-containment`);
an end-to-end instance create from the review UI succeeds at
`pr-999.review.fluxvale.app`; the sweep's label scope still matches.

### S7 — Janitor: 7-day TTL and lost-webhook backstop

**Context**: the close dispatch normally tears down; a lost webhook or
a deleted branch must not leave RAM behind (D7).

**Files** (fleet repo): `.github/workflows/review-janitor.yaml`,
reusing `scripts/review/teardown.sh`.

**Steps**: schedule `0 */6 * * *` + `workflow_dispatch`; list
namespaces with `fluxvale.io/review`; parse
`fluxvale.io/review-expires-at`; tear down the expired; optionally query
the PR state (best-effort; the TTL is the guarantee). One summary line
per env.

**Done when**:

```sh
# fake expired env
kubectl create ns fluxvale-pr-991
kubectl label ns fluxvale-pr-991 fluxvale.io/review=pr-991
kubectl annotate ns fluxvale-pr-991 fluxvale.io/review-expires-at=2020-01-01T00:00:00Z
gh workflow run review-janitor.yaml
kubectl get ns fluxvale-pr-991   # NotFound
```

a fresh fake env survives the same run; the run is under 2 minutes.

### S8 — Per-PR Playwright smoke (the pages leg)

**Context**: ADR-0024 promised per-PR Playwright. The `pages` leg is
already instance-free and env-driven through `BASE_URL`; run it against
the review env, informational (D8 keeps the merge meaning deployability,
not suite breadth). The open inbox (S2) means the TestInbox helper
needs no admin PAT.

**Files**: `.github/workflows/ci.yml` (new `review-env-e2e` job, needs
`review-env`, `BASE_URL=https://pr-<n>.review.fluxvale.app`),
`apps/e2e/tests/helpers/test-inbox.ts` (token optional when the inbox is
open), `apps/e2e/README.md`.

**Specs**: the existing pages leg —
`tests/custom-hostname.spec.ts tests/health.spec.ts
tests/landing.spec.ts tests/org-pages.spec.ts tests/policies.spec.ts
tests/public-pages.spec.ts tests/root-session.spec.ts
tests/sign-in.spec.ts tests/switcher-dismiss.spec.ts`.

**Done when**: the job runs green against a real review env, uploads
the HTML report on failure, and does **not** join `wait-for-ci`.

## Out of scope (deliberately)

- **Anything production-facing.** Review envs never touch the
  production namespace, DB, or secrets; fork CI has a read-only token,
  so fork PRs get no image push and no env — they review on staging.
- **A review-local MCP.** The handoff URL points at prod
  (`MCP_SERVER_URL` set explicitly); a follow-up can deploy the main MCP
  image at `mcp-pr-<n>.review` (+100m/128Mi) and flip the URL.
- **Payments, Postmark, private access, `/admin` mount, PostHog.**
  Staging-grade credentials in a PR-controlled pod are a worse trade
  than a partially inert UI.
- **Full destructive e2e per PR.** Only the pages leg; lifecycle stays
  on staging/nightly.
- **Per-env certificates, a second TLSStore, DNS automation.**
- **Scale-to-zero for the review platform itself.** TTL + cap are the
  cost levers; add a wake proxy only if idle hours dominate.
- **Staging's missing ResourceQuota**, CNPG requests/limits, per-env
  backups, a Postgres scratch cluster, network policies for review
  namespaces (a follow-up hardening slice), and the second box.

## Open for the go

1. **Cap 3 with LRU eviction** — or 2 (ADR-0024 said 2–3)? The measured
   headroom supports 3.
2. **Open TestInbox on review only** (D6) — accept the takeover of a
   disposable env?
3. **7-day TTL** (renewed on push) — right number?
4. **Required check** (`review-env` inside `Wait for CI`) — or
   informational for the first month?
5. Numbering: this lane started as "797"; the issue is **#798**.
   Confirm the doc/PR reference #798.
