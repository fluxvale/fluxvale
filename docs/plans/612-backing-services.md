# Plan: bundled per-instance backing services (#612)

Status: **APPROVED — Terence, Nov 8 2026.** All decisions D1–D8
settled as recommended; section 9 records the settlement. Slices fan
out per section 7; this doc rides S1's PR onto main (the
[597 precedent](597-pocketid-sso.md)).
Evidence base: the deployer and catalog types read at HEAD `a6da18c8`,
issue #612 + the waiting entries (#587 open PR, #609, #610), the
[OidcWiring precedent](../adr/README.md) as shipped, and the local k3d
cluster probed live (k8s **v1.37.0** — native sidecar containers, GA
since 1.29, fully in reach).

## 1. The design in one paragraph

An AppVersion may declare the backing services its app needs — today
Postgres and Redis, one of each at most — as catalog metadata a closed
type validates against the platform's approved-image registry. At
deploy, the deployer renders the declared services as containers inside
the instance's **own pod** (the PikaPods model): Postgres and Redis run
as native sidecar init containers with startup probes, so the app
container cannot start until both accept connections. Data lands on the
instance's existing `app-data` PVC under `backing/` subPaths;
credentials are generated once into a get-or-create K8s Secret (never
rotated), and the platform composes the declared `url_env` names
(`DATABASE_URL`, `REDIS_URL`) into the app's env above user values —
localhost URLs, no Services, no NetworkPolicy change. The services'
resource requests are carved **out of the purchased allocation** (the
DB eats the instance's envelope — honest sizing means bigger defaults,
not hidden overhead), so the quota math, stop/start/sleep/wake paths,
and the reconciler's readiness contract all stay untouched. The shared
CNPG cluster is not involved at all: this settles the per-instance half
of OQ #14 by avoidance, and a new ADR records the posture.

## 2. Ground truth this builds on (verified, not assumed)

- **The deployer's operand list is exactly**
  Namespace → RoleBinding → ResourceQuota → NetworkPolicy → PVC →
  app-env Secret → file-access Secret → Deployment → app Service → dav
  Service → edge. All server-side apply; every re-apply converges
  (`DeployInstance.apply_operands/3`).
- **The pod already carries a platform-owned extra container**: the
  file-access WebDAV sidecar (`Deployment.build_sidecar_container/1`),
  requests +0.05 CPU/+64 MB added **on top** of the allocation inside
  the quota — the existing precedent for platform overhead, and the
  counter-precedent this plan deliberately does NOT follow for DBs
  (D1).
- **The Instance is the snapshot**: create copies image, port, probe
  path, mount path, `file_access`, allocation, and the merged env onto
  the row; "editing an AppVersion later never mutates a running
  Instance's spec" (`Instance.DeriveFromAppVersion`). Instances pin
  their `app_version_id` at create — **no op changes it** — so a new
  version row can never retcon a live instance. This is what makes the
  BYO-takeover edge tractable (§5).
- **Env layering is explicit**: schema defaults < operator
  `default_env_vars` < user `env_vars` < `first_run.env` (contract
  above all, conflicts rejected loudly). Deploy-time seeds
  (`instance_url_env`, `host_allowlist_env`) land above user env via
  `Map.put`. Backing-service URLs join the deploy-time seed layer (§4.4).
- **The closed-type precedent is OidcWiring** (#597 S1): struct in
  memory, string-keyed map in jsonb, casting + validation in the type,
  cross-field validation in a dedicated `Ash.Resource.Validation`
  (`ValidateOidcWiringEnv`) that fails catalog writes — seeds,
  AshAdmin, and API enforce one contract. `backing_services` follows it
  exactly.
- **Honest sizing lives on the AppVersion row**:
  `default_cpu_cores`/`default_memory_mb`/`default_storage_gb` +
  `recommended_size` (locked equal by
  `ValidateSizeMatchesAllocation`), floored onto the slider rungs by
  the wizard; the below-recommendation path is ack-gated, not closed.
- **Stop/start/sleep/wake are all `Deployment.scale`** 0⇄1 — one pod
  scales, everything in it stops; the PVC persists; storage keeps
  billing. Readiness (`:running`) is written only by the reconciler,
  from the app container's readiness.

## 3. Reconciliation with the settled record

- **[ADR-0009](../adr/00009-single-cnpg-cluster.md) is untouched.**
  The shared CNPG cluster keeps its first-party cotenants; customer
  app databases never touch it. No amendment needed — the ADR's scope
  (where *platform* databases live) is not what this lane changes.
- **OQ #14 settles its per-instance half by avoidance.** The
  unsettled clause was "instances get platform-provisioned DBs" with
  an ADR-0009 amendment as the activation cost. Bundled containers
  pay none of that cost: no cluster involvement, no provisioning
  layer beyond the deployer itself. The managed-DB **product** shapes
  (DB-as-catalog-app, `fluxvale db`) stay deferred with their
  triggers; this lane is explicitly not them.
- **OQ #3's takeover trigger** (recorded by #587: "a future
  DB-provisioning layer would take ownership of `DATABASE_URL` the
  same way the deployer owns `instance_url_env`") is satisfied by
  design here — but **Umami's actual migration stays out of this
  lane** (Terence's sequencing: BYO interim, takeover later). The
  takeover semantics this lane ships are the ones that migration will
  use (§5, D6).
- **PikaPods precedent, translated**: local DB per pod, env-wired,
  pod-scoped resources. Our translation: one k8s pod per instance,
  DB sidecars in it, resources carved from the instance's envelope
  (their pod resource limits do the same job), data on the instance
  volume, stopped = storage-only.
- **#587 (open) is complementary, not conflicting.** Its 0-GB storage
  rung is for stateless entries; DB-backed entries get floors instead
  (D4). Its `DATABASE_URL`-as-BYO-input becomes the declared input a
  backing service takes over when an entry migrates (D6).

## 4. The design, piece by piece

### 4.1 Metadata type — `FluxVale.Catalog.Types.BackingService`

One attribute family on **AppVersion** (blueprint land, the
`oidc_wiring` precedent — per-version so an upstream breaking change
never re-wires older instances):

```yaml
backing_services:            # [] = none (every existing entry)
  - kind: postgres           # closed set: postgres | redis
    version: "18"            # major only; exact pin is platform-side
    url_env: DATABASE_URL    # the env the app expects; platform-owned
  - kind: redis
    version: "8"
    url_env: REDIS_URL
```

- `kind` — closed atom set, `OidcWiring.known_kinds/0`'s stance; at
  most **one service per kind** and **one service per `url_env`**.
- `version` — the **major** as a string. Must exist in the platform
  registry for that kind (below); anything else fails the catalog
  write.
- `url_env` — POSIX env name (`EnvVarSpec.valid_name?/1`).

A dedicated `ValidateBackingServices` (the `ValidateOidcWiringEnv`
pattern, wired on create + update) cross-checks against the same
version row:

- each `url_env` **exists in `configurable_env_vars`** with
  `secret: true` (the URL embeds the password — plain-typed is a
  catalog bug), and is **`required: false`** (the platform provides
  it; a required platform-owned input deadlocks the wizard);
- `url_env` stays disjoint from `first_run` keys (env ∪ forbidden),
  `instance_url_env`, `host_allowlist_env`, and the `oidc_wiring`
  recipe's named envs — one owner per key;
- no duplicate kinds, no duplicate `url_env`s.

Public JSON:API routes gain the field (names + majors only, never
values — the `oidc_callback_path` stance). The catalog detail page can
render "Bundled: PostgreSQL 18 · Redis 8" from it (S4 polish).

### 4.2 Image governance — platform registry, entry-declared major

A config key (the `:file_access` shape) maps kind + major → the
**exact-pinned image** and per-kind constants:

```elixir
config :flux_vale, :backing_services,
  postgres: %{"18" => %{image: "postgres:18.x…", port: 5432,
                        cpu: "0.10", memory_mb: 256}},
  redis:    %{"8"  => %{image: "redis:8.x…",    port: 6379,
                        cpu: "0.05", memory_mb: 64}}
```

- Catalog entries declare majors; the platform owns exact pins — one
  place to bump a CVE patch for every entry, no catalog edits. Exact
  tags + digest verification at seed time (the #587 upstream-facts
  discipline); the concrete versions are chosen in S1, not here.
- **The Instance snapshots the digest-resolved ref at create**
  ("the Instance is the snapshot"): the create path resolves the
  registry's tag to its digest and pins THAT onto the instance, and
  the Deployment renders the digest-pinned ref — a registry bump (or
  a re-pushed tag) can never shift a live instance's DB version under
  it, not on redeploy, not on resize. New instances of a bumped entry
  get the new pin.
- New engines (valkey, mariadb) join by growing this registry + the
  kind set — a deliberate diff, never a side effect.

### 4.3 Rendering — one pod, native sidecars, probe-gated ordering

The Deployment builder grows a `backing_services` spec entry (the
`sidecar` precedent's shape, rendered into `initContainers`):

```
initContainers:
  - postgres   (restartPolicy: Always — native sidecar)
      startupProbe: exec pg_isready   ← gates the next init
  - redis      (restartPolicy: Always)
      startupProbe: exec redis-cli ping
containers:
  - app        (unchanged probes; requests shrunk per §4.5)
  - file-access sidecar (if the app declares it — unchanged)
```

- **Native sidecar semantics do the ordering**: each init container
  with `restartPolicy: Always` must pass its startup probe before the
  next init container starts, and regular containers start only after
  all inits. The DBs' startup probes are `pg_isready -h 127.0.0.1` /
  `redis-cli ping` — **the app cannot start until both services accept
  TCP connections**. The `-h 127.0.0.1` is load-bearing: on first
  initialization the postgres image runs a temporary socket-only
  server, and a bare `pg_isready` would pass against it over the
  unix socket before TCP 5432 listens. No wait-loops, no command
  overrides (per-app command overrides are still open, OQ #3 — and
  stay untouched). Cluster floor: k8s ≥ 1.29 (local k3d probed
  v1.37; prod Talos is current). Fallback if probe semantics prove
  subtle in practice: explicit `wait-for-postgres`/`wait-redis` plain
  inits after the sidecars — same guarantee, one more moving part.
- **Listeners bind to loopback** (`listen_addresses=127.0.0.1` for
  postgres, `--bind 127.0.0.1 --protected-mode yes` for redis): the
  URL is `localhost` by design, so "nothing is exposed outside the
  pod" holds at the listener, not just at the network layer.
- **No new k8s Services.** Same-pod reachability is `localhost`:
  `postgres://…@localhost:5432/app`, `redis://:…@localhost:6379/0`.
  Nothing is exposed outside the pod, so NetworkPolicy and the
  edge are untouched. (The same-namespace floor already admits
  pod-to-pod anyway — a future multi-pod split wouldn't need a policy
  change either.)
- **Pod restart semantics fall out correctly**: app crash → kubelet
  restarts only the app container (DBs keep running); DB container
  crash → restarts in place, app sees a connection blip and reconnects
  (the same posture as any remote DB); node reboot / pod re-schedule →
  init ordering re-runs, data persists on the PVC.
- **The reconciler is unchanged.** Pod readiness stays the app
  container's contract. A DB that crash-loops holds the pod in
  `Init:` → `ProgressDeadlineExceeded` → the existing `:error` path.

### 4.4 Credentials + env wiring

One new K8s Secret per instance, name `backing-services`, the
`file-access` get-or-create discipline with a stronger reason:

- Generated once at first deploy: `POSTGRES_USER=fluxvale`,
  `POSTGRES_PASSWORD` (32-byte CSPRNG, URL-safe base64 — the existing
  `credential_password/0` pattern), `POSTGRES_DB=app`, and the
  composed `DATABASE_URL`; `REDIS_PASSWORD` + composed `REDIS_URL`
  (requirepass on — D7).
- **Never rotated**: the Postgres password hash lives in the PG data
  dir; rotating the Secret without `ALTER ROLE` locks the app out.
  An existing Secret IS the credential (READ FIRST is load-bearing,
  exactly as for `file-access`).
- DB containers read their env from this Secret (`envFrom`);
  probe commands read the password from env (`pg_isready` needs no
  auth; `REDISCLI_AUTH` covers `redis-cli`), never from argv — no
  secret lands in the pod spec.
- **App wiring rides the deploy-time seed layer**: `deploy_env/1`
  composes each declared `url_env` from the Secret and `Map.put`s it
  above user env — the `instance_url_env` stance. Ordering inside
  `apply_operands` changes one step: the `backing-services` Secret is
  get-or-created **before** env composition (it must exist to be
  read), joining the moduledoc's ordering notes. Resize keeps the URL
  for free — it reads the live `app-env` Secret as the envFrom
  witness already.
- **Instance-side takeover guard**: `DeriveFromAppVersion` grows a
  `backing_conflicts` arm — a user value naming a platform-owned
  `url_env` is **rejected loudly at create** (the `contract_conflicts`
  precedent), and the wizard never renders the input (§4.5). A crafted
  API value cannot silently shadow the bundled DB.

### 4.5 Resource accounting + honest sizing (D1, D4, D5)

**The DB eats the envelope** (the issue's words, taken literally):

- The pod's total requests stay exactly the purchased allocation.
  DB containers request fixed shares from the registry (PG 0.10 CPU /
  256 MB, Redis 0.05 / 64 MB — proposed; D1); the **app container's
  requests shrink** by the sum (CPU stays Decimal end-to-end — the
  quota's own rule). The ResourceQuota itself is unchanged:
  allocation + sidecar/backup margins, exactly as today.
- Contrast with file-access (+0.05/+64 on top): that sidecar is
  platform plumbing the user didn't buy; a database is half the
  workload the user IS buying. Honest pricing follows: entries with
  backing services ship **bigger defaults** (Docmost-class entries
  land at `medium`/`standard`, probed at implementation per the #609
  ~1 GB observation), and the stepper discloses the share in plain
  copy ("includes PostgreSQL 18 and Redis 8").
- **Floors close the under-provisioning paths for DB entries**:
  compute and storage cannot go below the version's defaults —
  `cpu_cores ≥ default_cpu_cores`, `memory_mb ≥ default_memory_mb`,
  `storage_gb ≥ default_storage_gb` — and the cpu floor is what keeps
  the carve non-negative: the defaults already INCLUDE the service
  shares (D1's honest-sizing stance), so flooring at the default
  guarantees the app request (allocation − shares) stays positive at
  create and at resize — the below-recommendation ack path is closed
  for DB entries because under-sizing starves the DB, and the DB's
  failure mode is the app's data integrity, not the app's latency.
  Enforced at instance create (validation) and reflected in the
  wizard (sliders floored; the 0-GB rung hidden — a DB entry at 0 GB
  has nowhere to put its data dir).
- Storage is one claim: DB data lives under `backing/` subPaths of
  `app-data` (below), inside the volume the user already pays for.

### 4.6 PVC layout

Same `app-data` claim, per-service subPaths — the first subPath use
in the deployer (the app's own mount stays at the volume root):

| Container | mountPath | subPath |
|---|---|---|
| app | `storage_mount_path` (root, unchanged) | — |
| postgres | `/var/lib/postgresql/data` | `backing/postgres` |
| redis | `/data` | `backing/redis` |

- PGDATA gets its own subdir (`…/data/pgdata`) — the official image's
  `lost+found` quirk on volume roots.
- The app can see `backing/` through its own mount; harmless, and
  honest (it's the app's database).
- Storage resize (up-only) widens the claim; both consumers grow into
  it. No layout migration ever needed — subPaths are stable from
  first deploy.

### 4.7 Lifecycle interactions

| Path | Behavior |
|---|---|
| Stop | `scale 0` — the whole pod (DBs included) stops; PVC persists; storage-only billing continues. Nothing new. |
| Start / wake | `scale 1` — init ordering re-runs; app boots after DBs. Nothing new. |
| Sleep (ADR-0036) | The scale path — free. Wake same. |
| Resize | Re-apply: app request recomputed (new allocation − DB shares), PVC widens, DB requests constant. The live-`app-env` witness keeps `DATABASE_URL`. |
| Redeploy / retry | SSA converges; get-or-create never rotates; snapshot pins the DB image. |
| Teardown | Namespace delete removes everything including DB data — destroy = data gone (existing posture, unchanged, stated in the ADR). |
| Backups | Posture unchanged: user-owned BYO S3 (ADR-0037 — un-quiesced copies, caveat scoped to the SQLite/git apps). For a bundled DB the honest tools are a **stopped-instance** backup or `pg_dump`: a file-level copy of a running PG data dir is not guaranteed restorable (the S3 backup copy says so for DB entries). A PG-native backup integration is a recorded later trigger. |

## 5. Edge cases, concretely

| Case | Behavior |
|---|---|
| **BYO takeover** — entry declares both a BYO input and a backing service for the same env | The backing service owns the key: wizard hides the input, deploy composes the platform value, a user value naming it is rejected at create (loud, the first-run stance). Existing instances are **never retconned** — they pin their version row; migration = a new version row + an owner-chosen move (new instance + data import). Umami's later takeover (OQ #3) reuses exactly this semantics as a deliberate per-instance op. |
| **DB major upgrade across app versions** | Snapshot pins the resolved image at create. A newer version row may declare a newer major; existing instances keep theirs. In-place PG major upgrade is a deferred trigger (documented in the ADR), not a shipped path. |
| Registry minor bump (18.x → 18.y) | Snapshot unaffected; only new instances pick it up. |
| App crash-loops | DBs keep running (native sidecars survive app restarts). |
| DB container crash / OOM | Restarts in place; app sees connection-refused until back (remote-DB blip posture); PVC data intact. |
| Node reboot / eviction | Pod re-created; ordering re-runs; data persists. |
| Stopped instance | Nothing runs, storage accrues — the DB is down with the app. Copy says so plainly (stopped rate is storage-only). |
| 0 GB or undersized compute craft | Rejected at create (floors at version defaults); wizard hides the 0 rung and floors sliders. |
| `file_access` + backing services together | Compose: app request = allocation − DB shares; DAV sidecar stays additive overhead (quota: allocation + sidecar + backup margins). |
| Private instance | `localhost` URLs are exposure-agnostic; no new ports, Services, or policy entries. |
| Backups of a live DB | File-level copy, not a guaranteed-restorable image (ADR-0045 names it plainly); stopped-instance backup or `pg_dump` are the honest tools. |
| Version row edited after instances exist | Nothing — instances are snapshots; the doctrine holds for the new field. |

## 6. ADR sketch — `00045-bundled-backing-services.md`

- **Decision**: catalog-declared backing services (Postgres, Redis) as
  containers inside the instance's own pod — native sidecars with
  probe-gated ordering, data on the instance PVC under `backing/`,
  generated credentials in a get-or-create Secret, env composed at
  deploy into declared `url_env` names, resources carved from the
  purchased allocation. PikaPods precedent named.
- **What it settles**: OQ #14's per-instance clause (by avoidance);
  OQ #3's takeover trigger gets its semantics; ADR-0009 untouched
  (shared cluster stays first-party-only, no amendment).
- **Rejected alternatives** (the part that stops re-litigation):
  - *Per-tenant databases in the shared CNPG cluster* — needs the
    ADR-0009 amendment (customer DBs in a first-party envelope),
    couples customer blast radius to the billing ledger, and buys
    nothing at single-node scale; stays the managed-DB product's
    question (OQ #14, deferred).
  - *Separate Deployment/StatefulSet per service* — cross-pod
    readiness ordering, separate quota accounting, Services +
    NetworkPolicy entries, and stop/start paths that must coordinate
    multiple objects — complexity for zero isolation gain (same
    namespace, same node, same volume either way).
  - *Managed DBaaS* — cost and region coupling; the traction-onset
    migration trigger (ADR-0009 guardrail 1) already names that
    escape hatch for apps that outgrow the bundled model.
  - *Resources as platform overhead on top* (the file-access stance) —
    rejected for honesty: the DB is purchased workload, not plumbing.
- **Posture statements**: backups stay user-owned (BYO S3); a live
  file-level copy is not a guaranteed-restorable DB image (stopped
  backup or pg_dump are the honest tools); destroy = data gone;
  in-place DB major upgrades deferred with a trigger.

## 7. Slices

Each lands green (`mix ci`), one PR per slice, umbrella issue #612
referenced without closing until the last. S1 carries this plan + the
ADR once approved.

- **S1 Catalog metadata + decision records** — the `BackingService`
  type, the `backing_services` attribute, `ValidateBackingServices`,
  the image registry config (exact pins + digest verification, the
  #587 upstream-facts discipline), JSON:API exposure; no entry
  declares services yet. Carries the plan doc + ADR-0045 + the OQ
  #14 / OQ #3 write-backs onto main.
  *Done when:* every invalid shape fails the catalog write (closed
  kinds, registry-unknown majors, non-secret or missing or
  `required:true` `url_env`s, first-run/url-seed collisions, duplicate
  kinds/envs); seeds converge; public routes render the field;
  loader/seed tests pin it.
- **S2 Snapshot + deployer rendering** — the instance snapshot
  (additive migration; the derive change), the `backing-services`
  Secret (get-or-create), the apply-order change + env composition
  (takeover precedence), the Deployment rendering (native sidecars,
  probe gating, subPath volume mounts, PGDATA), resource carving,
  resize/stop/start interactions.
  *Done when:* manifest tests pin the pod shape (init order, probes,
  subPaths, requests arithmetic = allocation exactly, loopback
  listener bindings); mocked deploy tests pin Secret get-or-create +
  env composition; a local k3d fixture deploy boots app-after-DB and
  survives a pod delete with data intact, and a pod-IP network check
  confirms the DB listeners are unreachable off-loopback.
- **S3 Honest sizing + wizard** — create-time floors (memory/storage
  at version defaults), the wizard's hidden inputs (platform-owned
  `url_env`s), hidden 0-GB rung for DB entries, floored sliders, the
  stepper's bundled-services disclosure copy.
  *Done when:* LiveView tests pin the wizard behavior; undersized /
  0 GB / platform-owned-key crafts fail create with honest messages;
  copy reviewed for the plain-sentence rule.
- **S4 First consumer — Docmost (#609)** — the entry (verified image,
  `postgres` + `redis` declarations, honest defaults probed from the
  running image per its own issue), staging proof, and the e2e
  lifecycle spec with the two new legs: **restart** (destroy pod →
  data persists) and **stop/start** (storage-only interlude → data
  persists).
  *Done when:* staging deploy → health 200 → first-run verified;
  e2e green on the CI lifecycle leg; the paid-tier copy disclosures
  of #609 hold; Closes #609.

**Order**: S1 → S2 → S3 → S4 (S3 can start beside S2's tail; S4 needs
all three). Residuals recorded, not sliced: the Umami BYO→bundled
takeover op (OQ #3's recorded trigger, Terence's later lane); Vikunja
(#610) as the PG-only second entry on its own issue; registry growth
(valkey, mariadb); PG-native backup integration; in-place DB major
upgrades.

## 8. Risks

- **Native-sidecar semantics subtleties** (probe-gated init
  progression): mitigated by the local-cluster boot proof in S2 and
  the explicit-wait fallback; k8s floor documented in the ADR.
- **Postgres under a hard memory limit**: requests/limits follow the
  house 2x convention; PG's OOM posture is crash-recovery (WAL). The
  256 MB request is conservative for catalog-class apps; the floor
  rules keep allocations realistic. Watch the first staging consumer.
- **Env-snapshot interactions**: `DATABASE_URL` lands at deploy like
  `ROOT_URL` — a running app's Secret isn't rewritten by later
  changes (the established stance); get-or-create guarantees the
  value is stable anyway.
- **Registry config drift between envs** (staging/prod pins):
  runtime config in the fleet repo per env — same discipline as
  `:file_access`; the ADR names it.
- **Catalog validation tightness**: the closed type + registry means
  an upstream env rename fails the seed, not the deploy (the
  OidcWiring lesson, applied earlier).
- **Honesty of "one of each kind"**: apps needing two databases
  (rare in this catalog class) are out of scope by design; the type
  rejects the shape loudly if catalog data tries.

## 9. Terence's decisions — open, recommended

- **D1 Resource posture — carve from the purchased envelope**
  (recommended; the issue's own words, PikaPods parity, honest
  pricing) vs. platform overhead on top (the file-access stance).
  Includes the proposed shares: PG 0.10 CPU / 256 MB, Redis 0.05 /
  64 MB.
- **D2 Image governance — platform registry owns exact pins; entries
  declare majors; instances snapshot the resolved ref at create**
  (recommended) vs. catalog-carried full refs vs. render-time
  resolution (registry bumps flowing to live instances).
- **D3 First consumer — Docmost** (recommended: exercises PG + Redis,
  the full model; single app image; resolves #609's STOP-clause
  investigation) vs. Vikunja (PG-only; its two-image upstream shape
  is its own risk).
- **D4 Storage floor — version-default floor, 0-GB rung hidden for
  DB entries** (recommended) vs. a fixed 5 GB floor for all DB
  entries.
- **D5 Compute floor — close the below-recommendation path for DB
  entries** (recommended: under-sizing starves the DB) vs. keep it
  ack-gated as today.
- **D6 Takeover semantics — loud create-time rejection + hidden
  input + never retcon pinned instances** (recommended; the
  first-run-contract stance) vs. silent deploy-time override (the
  ROOT_URL stance).
- **D7 Redis auth — generated `requirepass`** (recommended; the URL
  carries it, posture uniform) vs. open localhost (marginally
  simpler, weaker by construction).
- **D8 Readiness mechanism — native sidecars with startup probes**
  (recommended; cluster verified v1.37) vs. explicit wait-init
  containers vs. app-side retry only (not owned by the platform —
  rejected in the ADR regardless).

## Settled — Terence, Nov 8 2026

All eight accepted as recommended. Two emphases ride the slices
verbatim ([ADR-0045](../adr/00045-bundled-backing-services.md)):

- **D5**: the below-recommendation path for DB-backed entries
  **refuses, don't sell broken** — floors are hard rejections, not
  warnings.
- **D6**: the loud takeover rejection is a **TESTED behavior** — a
  failing create with an honest error, never a log line.
