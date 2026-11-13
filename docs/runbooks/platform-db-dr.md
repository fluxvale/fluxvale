# Runbook: platform database — backup verification and PITR restore drill

**Internal.** The shared CNPG cluster's `platform_prod` database
([ADR-0009](../adr/00009-single-cnpg-cluster.md)). Production and
staging are **read-only** in this procedure — list, read, verify only.
The restore target is an **isolated local cluster**, created for the
drill and destroyed after. Customer-volume backups are a different
system ([ADR-0037](../adr/00037-instance-backups-s3.md)).

Drill record: #758, 2026-11-13. The acceptance bar: a second operator
following §5 verbatim can repeat the restore.

Operational literals (bucket, endpoint) are not restated here — the
procedure reads them from the live `Cluster` spec, per
[ADR-0018](../adr/00018-repo-visibility.md)'s disclosure boundary.

## 1. What is protected

| | |
|---|---|
| Cluster | `fluxvale-cnpg`, namespace `fluxvale-db`, one instance, PostgreSQL 18 |
| Backup | `spec.backup.barmanObjectStore` — CNPG's barman object store to Cloudflare R2 |
| Layout | `<destinationPath>/<serverName>/{base,wals}/…`; `serverName` is `fluxvale-cnpg` |
| Schedule | `ScheduledBackup/fluxvale-cnpg-daily`, expression `0 3 * * *` — **hourly at :03**, not daily 03:00 (§8) |
| Retention | `spec.backup.retentionPolicy: 30d` |
| Credentials | 1Password item `cnpg-backup` in the production vault, fields `username`/`password`; rendered in-cluster as Secret `fluxvale-db/fluxvale-cnpg-backup` with the same keys |
| Operator | CNPG 1.30.x, native barman support (deprecated — §8); read the exact deployed version from `kubectl -n cnpg-system get deploy` |

The backup is **cluster-wide**: every tenant database in the shared
cluster rides the same base backup and WAL stream. There is no
per-database backup; per-tenant recovery is PITR to a scratch cluster,
then dump/import the tenant ([ADR-0009](../adr/00009-single-cnpg-cluster.md)
guardrail 2).

## 2. Verify the chain (read-only, before every drill)

Run from a workstation with the production context. Every command is
GET/LIST.

```sh
export KCTX=admin@fluxvale

kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg
kubectl --context "$KCTX" -n fluxvale-db get backup \
  --sort-by=.status.stoppedAt | tail -5
kubectl --context "$KCTX" -n fluxvale-db get scheduledbackup fluxvale-cnpg-daily \
  -o jsonpath='{.spec.schedule}{" last="}{.status.lastScheduleTime}{" next="}{.status.nextScheduleTime}{"\n"}'
```

Expect `Cluster in healthy state`, `ContinuousArchiving=True`,
`LastBackupSucceeded=True`, and a completed backup newer than the
current hour. `status.lastFailedBackup` may still name an old failure
(2026-10-02 here); that is history once `lastSuccessfulBackup` is
current.

Object side — the destination and endpoint come from the live spec, so
they are never copied into this repo:

```sh
DEST=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
ENDPOINT=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.endpointURL}')

# Values are read into files, never echoed and never passed as argv.
umask 077
op read 'op://fluxvale-production/cnpg-backup/username' > /tmp/fv-r2-user
op read 'op://fluxvale-production/cnpg-backup/password' > /tmp/fv-r2-pass

AWS_ACCESS_KEY_ID=$(cat /tmp/fv-r2-user) \
AWS_SECRET_ACCESS_KEY=$(cat /tmp/fv-r2-pass) \
AWS_DEFAULT_REGION=auto \
aws --endpoint-url "$ENDPOINT" s3 ls "$DEST/fluxvale-cnpg/base/" | tail -3

AWS_ACCESS_KEY_ID=$(cat /tmp/fv-r2-user) \
AWS_SECRET_ACCESS_KEY=$(cat /tmp/fv-r2-pass) \
AWS_DEFAULT_REGION=auto \
aws --endpoint-url "$ENDPOINT" s3 ls "$DEST/fluxvale-cnpg/wals/" | tail -3

AWS_ACCESS_KEY_ID=$(cat /tmp/fv-r2-user) \
AWS_SECRET_ACCESS_KEY=$(cat /tmp/fv-r2-pass) \
AWS_DEFAULT_REGION=auto \
aws --endpoint-url "$ENDPOINT" s3 ls "$DEST" --recursive --human-readable --summarize | tail -2

rm -f /tmp/fv-r2-user /tmp/fv-r2-pass
```

If `op` cannot authenticate unattended, the rendered Secret is the
read-only fallback (a GET): `kubectl get secret fluxvale-cnpg-backup
-o jsonpath='{.data.username}' | base64 -d`. Hardened variant: mint a
read-only R2 token for drills, so the credential cannot write even by
mistake.

### Drill evidence — 2026-11-13T10:45Z

| Check | Result |
|---|---|
| Cluster | `Cluster in healthy state`, primary `fluxvale-cnpg-1` |
| Continuous archiving | `True` (`ContinuousArchivingSuccess`) |
| Last successful backup | 2026-11-13T10:03:24Z, `LastBackupSucceeded=True` |
| Newest base backup | `20261113T100300` — `data.tar` 160,296,960 B, 10:03:33Z; `backup.info` 1,449 B |
| Newest WAL at drill start | `…002F0000008F.gz`, 488,585 B, 10:48:25Z (≈5 min lag) |
| Archive size | 360 base backups, 5,940 objects, 43.7 GiB |
| Retention / chain age | 30d policy; first recoverability 2026-10-29T11:55:05Z |
| Last failed backup | 2026-10-02T12:20:50Z — pre-fix; none since |

## 3. PITR window and target choice

The usable window is `status.firstRecoverabilityPoint` → the newest
archived WAL:

| | 2026-11-13 |
|---|---|
| First recoverability point | 2026-10-29T11:55:05Z |
| Newest archived WAL | 2026-11-13T10:48:25Z |
| Drill target | 2026-11-12T10:00:00Z |

The window is shorter than the 30d policy because the chain **starts**
at the first successful base backup (the pre-Oct-29 attempts failed).
It grows to 30d as the chain ages; after 2026-11-28 the policy is the
binding limit.

Choose a target with rows on both sides, so the drill proves PITR
rather than "restore everything":

```sh
kubectl --context "$KCTX" -n fluxvale-db exec fluxvale-cnpg-1 -- \
  psql -U postgres -d platform_prod -AtF'|' -c "
select 'organizations',max(created_at) from organizations
union all select 'users',max(created_at) from users
union all select 'instances',max(created_at) from instances
union all select 'memberships',max(created_at) from memberships
union all select 'billing_ledger_entries',max(created_at) from billing_ledger_entries
order by 1;"
```

On 2026-11-13 the newest row was a ledger entry at
`2026-11-12T10:00:01.277507Z`. Target `2026-11-12T10:00:00Z` sits 1.3s
before it: the restore must contain the five earlier ledger rows and
**not** the sixth.

## 4. Isolation envelope (hard rules)

- Restore only into a **local k3d cluster** (here: the `k3d-fluxvale`
  context), in its own namespace (`dr-drill`). No `Cluster`, `Job`, or
  `Secret` is ever created in the production or staging namespaces.
- Production access is `kubectl get/exec … psql SELECT` only. No
  scale, patch, apply, or delete against `admin@fluxvale`.
- R2 access is LIST/GET. No `backup`, `prune`, or `delete` command
  touches the bucket.
- The restore `Cluster` has **no `spec.backup` stanza** — it is a
  recovery consumer, not an archiver. Verify no new timeline appears in
  the bucket after promotion (§6).
- Tear down the namespace after evidence capture. A leftover scratch
  cluster is both a full data copy and a future no-op trap.

## 5. Restore procedure

Prerequisites: `kubectl`, `aws` (or an S3 client), `op`, a local k3d
cluster with the CNPG operator installed (the operator version should
match production's minor — 1.30.x here), and ~2× the base backup size
free on disk (the PVC below is 4 GiB; the 2026-11-13 base was 153 MiB).

### 5.1 Snapshot the live boundary (read-only)

Pick `TARGET` per §3 and record it. Set both the shell value and the
matching `\set` line below (RFC3339 for Kubernetes, a Postgres
timestamp for the queries) to the same instant. Then capture the live
rows at and after the boundary with `dr-verify.sql`:

```sh
cat > /tmp/dr-verify.sql <<'SQL'
\set target '2026-11-12 10:00:00+00'

select 'counts_at_target', t, n from (
  select 'organizations' t, count(*) n from organizations where created_at <= :'target'
  union all select 'users', count(*) from users where created_at <= :'target'
  union all select 'instances', count(*) from instances where created_at <= :'target'
  union all select 'memberships', count(*) from memberships where created_at <= :'target'
  union all select 'billing_ledger_entries', count(*) from billing_ledger_entries where created_at <= :'target'
) s order by t;

select 'post_target', t, n from (
  select 'organizations' t, count(*) n from organizations where created_at > :'target'
  union all select 'users', count(*) from users where created_at > :'target'
  union all select 'instances', count(*) from instances where created_at > :'target'
  union all select 'memberships', count(*) from memberships where created_at > :'target'
  union all select 'billing_ledger_entries', count(*) from billing_ledger_entries where created_at > :'target'
) s order by t;

select 'checksum', t, n, h from (
  select 'organizations' t, count(*) n,
         md5(string_agg(id::text||'|'||slug||'|'||created_at::text, E'\n' order by id)) h
    from organizations where created_at <= :'target'
  union all select 'users', count(*),
         md5(string_agg(id::text||'|'||created_at::text, E'\n' order by id))
    from users where created_at <= :'target'
  union all select 'instances', count(*),
         md5(string_agg(id::text||'|'||slug||'|'||status||'|'||created_at::text, E'\n' order by id))
    from instances where created_at <= :'target'
  union all select 'memberships', count(*),
         md5(string_agg(id::text||'|'||organization_id::text||'|'||user_id::text||'|'||created_at::text, E'\n' order by id))
    from memberships where created_at <= :'target'
  union all select 'billing_ledger_entries', count(*),
         md5(string_agg(id::text||'|'||wallet_id::text||'|'||amount::text||'|'||type||'|'||reason||'|'||created_at::text, E'\n' order by id))
    from billing_ledger_entries where created_at <= :'target'
) s order by t;
SQL

kubectl --context "$KCTX" -n fluxvale-db exec -i fluxvale-cnpg-1 -- \
  psql -U postgres -d platform_prod -AtF'|' -f - < /tmp/dr-verify.sql \
  | tee /tmp/dr-live.txt
```

Run the same file against the restored cluster in §5.5; only the exec
target changes. Record the snapshot wall-clock time next to the output.

### 5.2 Scratch namespace and credentials

```sh
export DRCTX=k3d-fluxvale
kubectl --context "$DRCTX" create namespace dr-drill

umask 077
op read 'op://fluxvale-production/cnpg-backup/username' > /tmp/fv-r2-user
op read 'op://fluxvale-production/cnpg-backup/password' > /tmp/fv-r2-pass
kubectl --context "$DRCTX" -n dr-drill create secret generic r2-creds \
  --from-file=username=/tmp/fv-r2-user \
  --from-file=password=/tmp/fv-r2-pass
rm -f /tmp/fv-r2-user /tmp/fv-r2-pass
```

### 5.3 Apply the recovery cluster

`DEST` and `ENDPOINT` are read from production's spec (same values as
§2). The heredoc is unquoted on purpose: the shell substitutes them.

```sh
DEST=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
ENDPOINT=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.endpointURL}')
TARGET=2026-11-12T10:00:00Z   # your §5.1 value, RFC3339

kubectl --context "$DRCTX" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: fluxvale-cnpg-dr
  namespace: dr-drill
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18
  storage:
    storageClass: local-path
    size: 4Gi
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "${TARGET}"
  externalClusters:
    - name: origin
      barmanObjectStore:
        destinationPath: ${DEST}
        endpointURL: ${ENDPOINT}
        serverName: fluxvale-cnpg
        s3Credentials:
          accessKeyId:
            name: r2-creds
            key: username
          secretAccessKey:
            name: r2-creds
            key: password
        wal:
          compression: gzip
          maxParallel: 4
  postgresql:
    parameters:
      shared_buffers: 256MB
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 1Gi
EOF
```

CNPG 1.30 prints a deprecation warning for native `barmanObjectStore` on
apply. Expected here (§8).

### 5.4 Wait, and record the wall time

```sh
date -u +%FT%TZ
kubectl --context "$DRCTX" -n dr-drill wait \
  --for=condition=Ready cluster/fluxvale-cnpg-dr --timeout=15m
date -u +%FT%TZ
```

`Ready` is the usable state — the instance is promoted (`pg_is_in_recovery()
= false`) and serving. Expect ~3 min for a 153 MiB base plus the WAL
replay; scale with database size and the distance from the target to
the nearest base backup.

### 5.5 Verify row-level integrity

```sh
kubectl --context "$DRCTX" -n dr-drill exec -i fluxvale-cnpg-dr-1 -- \
  psql -U postgres -d platform_prod -AtF'|' -f - < /tmp/dr-verify.sql \
  | tee /tmp/dr-restored.txt

diff -u <(grep -v '^post_target|' /tmp/dr-live.txt) \
        <(grep -v '^post_target|' /tmp/dr-restored.txt)   # exit 0 = counts+checksums match
grep '^post_target|' /tmp/dr-restored.txt                 # every row count must be 0
```

The `post_target` block is deliberately different: live has rows after
the target, the restored cluster must not. The first `diff` compares
only the counts-at-target and checksum lines.

Then confirm the promotion and the absence of an archive:

```sh
kubectl --context "$DRCTX" -n dr-drill exec fluxvale-cnpg-dr-1 -- \
  psql -U postgres -d platform_prod -Atc \
  "select pg_is_in_recovery(), timeline_id from pg_control_checkpoint();"
# expect: f|2

AWS_ACCESS_KEY_ID=$(op read 'op://fluxvale-production/cnpg-backup/username') \
AWS_SECRET_ACCESS_KEY=$(op read 'op://fluxvale-production/cnpg-backup/password') \
AWS_DEFAULT_REGION=auto \
aws --endpoint-url "$ENDPOINT" s3 ls "$DEST/fluxvale-cnpg/wals/" \
  | grep '^ *PRE 00000002' || echo "no timeline-2 WAL — recovery cluster did not archive"
```

A timeline-2 prefix means the scratch cluster archived; stop and
investigate before the next drill (the manifest must stay
recovery-only).

### 5.6 Teardown

```sh
kubectl --context "$DRCTX" delete namespace dr-drill --wait=true
kubectl --context "$DRCTX" get namespace dr-drill          # expect NotFound
kubectl --context "$DRCTX" get pv -o json \
  | jq -r '.items[] | select(.spec.claimRef.namespace=="dr-drill") | .metadata.name'
rm -f /tmp/dr-verify.sql /tmp/dr-live.txt /tmp/dr-restored.txt
```

## 6. What the 2026-11-13 drill verified

### Restore timeline

| Step | UTC |
|---|---|
| `Cluster` applied | 10:52:39 |
| `Initialized=True` | 10:52:42 |
| `Ready=True` (usable) | 10:55:42 |
| **Apply → Ready** | **3m03s** |
| Namespace deleted | 10:57:05 → 10:57:35 (30.6s) |

The `kubectl wait` measured 2m57s because it started six seconds after
apply; use the condition timestamps above.

### Row integrity (target `2026-11-12T10:00:00Z`)

| Table | Live ≤ target | Restored | Checksum (live = restored) |
|---|---|---|---|
| `organizations` | 3 | 3 | `f02605f75c161989ec33a17ca6dc99b9` |
| `users` | 3 | 3 | `51aa60eb7fc5f93a4c866268cbe97ce6` |
| `instances` | 1 | 1 | `86729f1eda84fc9fe3ae21e307a08f35` |
| `memberships` | 3 | 3 | `b9c217020bbb3317987764016dd2c1ea` |
| `billing_ledger_entries` | 5 | 5 | `4b307e762a8c1ac5d9dc3eb0748f13a8` |

PITR boundary proof:

| Check | Live | Restored |
|---|---|---|
| Ledger rows `created_at > target` | 1 | 0 |
| Newest ledger `created_at` | 2026-11-12T10:00:01.277507Z | 2026-11-11T03:30:01.216073Z |
| `pg_is_in_recovery()` / timeline | n/a | `f` / `2` |
| Timeline-2 WAL objects in the bucket | — | 0 |

The latest meaningful rows — the `terenceponce` organization
(`01a1b0ac-3c93-7239-8ccd-9c3e71459e9c`), its user
(`01a1b0ac-3c8d-703c-a8cf-6e39affab9f4`), the `memos` instance
(`01a1bde6-b93a-77fa-b5c2-51f9c6675cd6`, `sleeping`) and their
membership — were present in both. The live read was taken at
2026-11-13T10:52:11Z; the checksums pin it to `created_at <= target`.

### Isolation

| Check | Result |
|---|---|
| Scratch namespace after teardown | `NotFound`; no PV left |
| Production/staging writes | none — GET/LIST/SELECT only |
| New R2 objects during the drill | the live cluster's own WAL segment `2F/90` at 10:53:25Z |
| Restore cluster archive | no `spec.backup` stanza; no timeline-2 prefix |

## 7. Delta vs the Thalmyra rehearsal (2026-10-16)

Same toolchain class (CNPG barman PITR into k3d), different cluster and
database:

| | Thalmyra, 2026-10-16 | Platform, 2026-11-13 |
|---|---|---|
| Recovery point | 2026-10-15T12:00Z | 2026-11-12T10:00Z |
| Target | local k3d | local k3d, `dr-drill` namespace |
| Apply → healthy | ~3 min | 3m03s |
| Data at target | near-empty tenant — 5 tables, 8 migrations, 0 players | 3 orgs, 3 users, 1 instance, 3 memberships, 5 ledger rows |
| Verification | dump row counts | per-table checksums, live vs restored, plus PITR exclusion |
| Isolation | rehearsal on k3d; the current Thalmyra runbook still restores into `fluxvale-db` on the production cluster and dumps from there | local-only namespace; zero production resources |
| Credential keys | doc says `accessKeyID`/`secretAccessKey` | live Secret keys are `username`/`password` (fv-309 W5) — the Thalmyra copy is stale |

The platform drill is the stricter one: it validates a real row set and
proves the restore stops at the target, on a target that never touches
the shared cluster.

## 8. Findings and owner follow-ups (not changed here)

- **The schedule is hourly, not daily.** CNPG's `ScheduledBackup`
  cron has a seconds field; the 5-field `0 3 * * *` parses as
  "second 0, minute 3, every hour". Evidence: `lastScheduleTime`
  10:03 → `nextScheduleTime` 11:03, and 360 base backups over 15 days.
  If daily 03:00 was intended, the expression is `0 0 3 * * *`.
  Changing cadence or retention changes R2 spend — owner decision.
- **Native barman is deprecated.** The operator warns that
  `barmanObjectStore` support is removed in CNPG 1.31. The deployed
  line is 1.30.x; migrate the cluster to the Barman Cloud Plugin
  **before** any 1.31 upgrade, or recovery breaks. This runbook works
  on 1.30.x.
- **Retention is not the current constraint.** The 30d policy is
  binding only after 2026-11-28; until then the chain's Oct-29 start is.
- **Thalmyra's runbook key names are stale** (`accessKeyID`/
  `secretAccessKey` vs the rendered `username`/`password`). A restore
  followed verbatim today fails at the credential step.
- **Hardened variant:** a read-only R2 token for drills removes write
  capability from the credential; today isolation is by construction
  (recovery-only manifest, no bucket writes issued).

## 9. Repeatability checklist

- [ ] §2 chain green: archiving `True`, fresh completed base, fresh WAL.
- [ ] §3 target recorded, with live rows on both sides of it.
- [ ] §5.1 live snapshot saved with its wall-clock time.
- [ ] §5.4 apply → `Ready` recorded (expect minutes, not tens of minutes).
- [ ] §5.5 checksums identical, post-target rows absent, timeline 2.
- [ ] §5.5 no timeline-2 WAL prefix in the bucket.
- [ ] §5.6 namespace gone, no PV, temp files removed.
- [ ] Add a row to the drill log below.

### Drill log

| Date (UTC) | Operator | Target | Apply → Ready | Result |
|---|---|---|---|---|
| 2026-10-16 | Thalmyra rehearsal | 2026-10-15T12:00Z | ~3 min | pass (tenant, near-empty) |
| 2026-11-13 | Terence | 2026-11-12T10:00Z | 3m03s | pass (platform_prod, checksums) |
