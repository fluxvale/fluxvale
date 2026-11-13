# Runbook: platform database — backup verification and PITR restore drill

**Internal.** The shared CNPG cluster's `platform_prod` database
([ADR-0009](../adr/00009-single-cnpg-cluster.md)). Production and
staging are **read-only** in this procedure — list, read, verify only.
The restore target is an **isolated local cluster**, created for the
drill and destroyed after. Customer-volume backups are a different
system ([ADR-0037](../adr/00037-instance-backups-s3.md)).

Drill record: #758, 2026-11-13. The acceptance bar: a second operator
following §5 verbatim can repeat the restore.

This internal runbook is the one carve-out in
[ADR-0018](../adr/00018-repo-visibility.md) Amendment 2: it may live in
this repo because the launch gate requires repeatable evidence here.
Bucket, endpoint, and credentials still never appear — the procedure
reads them from the live `Cluster` spec at run time.

## 1. What is protected

| | |
|---|---|
| Cluster | `fluxvale-cnpg`, namespace `fluxvale-db`, one instance, PostgreSQL 18 |
| Backup | `spec.backup.barmanObjectStore` — CNPG's barman object store to Cloudflare R2 |
| Layout | `<destinationPath>/<serverName>/{base,wals}/…`; `serverName` is `fluxvale-cnpg` |
| Schedule | `ScheduledBackup/fluxvale-cnpg-daily`, expression `0 3 * * *` — **hourly at :03**, not daily 03:00 (§8) |
| Retention | `spec.backup.retentionPolicy: 30d` |
| Credentials | 1Password item `cnpg-backup` in the production vault, fields `username`/`password`; rendered in-cluster as Secret `fluxvale-db/fluxvale-cnpg-backup` with the same keys |
| Operator | CNPG 1.30.x line with native barman support; the exact version is read from the live cluster, not pinned here |

The destination already ends in the cluster name, and barman appends
`serverName` again: the effective prefix is
`…/v2/fluxvale-cnpg/fluxvale-cnpg/{base,wals}/`. The commands below
handle that; only hand-built paths need the note.

The backup is **cluster-wide**: every tenant database in the shared
cluster rides the same base backup and WAL stream. There is no
per-database backup; per-tenant recovery is PITR to a scratch cluster,
then dump/import the tenant ([ADR-0009](../adr/00009-single-cnpg-cluster.md)
guardrail 2).

## 2. Verify the chain (read-only, before every drill)

Run from a workstation with the production context. Every command is
GET/LIST. Use **bash** (the credential fallback and later parameter
expansion assume it).

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
they are never copied into this repo. `op read -n` is not optional:
a trailing newline in an S3 key produces `SignatureDoesNotMatch` and a
restore that never reaches `Ready`.

```sh
DEST=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
ENDPOINT=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.endpointURL}')

umask 077
if op read -n 'op://fluxvale-production/cnpg-backup/username' > /tmp/fv-r2-user 2>/dev/null &&
   op read -n 'op://fluxvale-production/cnpg-backup/password' > /tmp/fv-r2-pass 2>/dev/null; then
  :
else
  # Read-only fallback when op cannot authenticate: the rendered Secret.
  kubectl --context "$KCTX" -n fluxvale-db get secret fluxvale-cnpg-backup \
    -o jsonpath='{.data.username}' | base64 -d > /tmp/fv-r2-user
  kubectl --context "$KCTX" -n fluxvale-db get secret fluxvale-cnpg-backup \
    -o jsonpath='{.data.password}' | base64 -d > /tmp/fv-r2-pass
fi
test -s /tmp/fv-r2-user && test -s /tmp/fv-r2-pass || { echo "credential read failed"; exit 1; }
export AWS_ACCESS_KEY_ID="$(cat /tmp/fv-r2-user)"
export AWS_SECRET_ACCESS_KEY="$(cat /tmp/fv-r2-pass)"

NEWEST_BASE=$(TZ=UTC aws --endpoint-url "$ENDPOINT" s3 ls "$DEST/fluxvale-cnpg/base/" | tail -1 | awk '{print $2}')
TZ=UTC aws --endpoint-url "$ENDPOINT" s3 ls "$DEST/fluxvale-cnpg/base/$NEWEST_BASE"
TZ=UTC aws --endpoint-url "$ENDPOINT" s3 ls "$DEST/fluxvale-cnpg/wals/" --recursive | sort | tail -3
TZ=UTC aws --endpoint-url "$ENDPOINT" s3 ls "$DEST" --recursive --human-readable --summarize | tail -2
```

Keep the two credential files for §5.2; delete them after the scratch
Secret is verified. A hardened variant is a read-only R2 token, so the
drill credential cannot write even by mistake.

### Drill evidence — 2026-11-13T11:28Z

| Check | Result |
|---|---|
| Cluster | `Cluster in healthy state`, primary `fluxvale-cnpg-1` |
| Continuous archiving | `True` (`ContinuousArchivingSuccess`) |
| Last successful backup | 2026-11-13T11:03:28Z, `LastBackupSucceeded=True` |
| Newest base backup | `20261113T110300` — `data.tar` 160,307,200 B, `backup.info` 1,447 B, both 11:03:35Z |
| Newest WAL at snapshot | `…002F00000099.gz`, 269,359 B, 11:28:31Z (≈5 min lag) |
| Archive size | 361 base backups, 5,952 objects, 43.9 GiB |
| Retention / chain age | 30d policy; first recoverability 2026-10-29T11:55:05Z |
| Last failed backup | 2026-10-02T12:20:50Z — pre-fix; none since |

## 3. PITR window and target choice

The usable window is `status.firstRecoverabilityPoint` → the newest
archived WAL:

| | 2026-11-13 |
|---|---|
| First recoverability point | 2026-10-29T11:55:05Z |
| Newest archived WAL | 2026-11-13T11:28:31Z |
| Drill target | 2026-11-13T11:20:30Z |

The window is shorter than the 30d policy because the chain **starts**
at the first successful base backup (the pre-Oct-29 attempts failed).
It grows to 30d as the chain ages; after 2026-11-28 the policy is the
binding limit.

`created_at`/`inserted_at` are `timestamp without time zone` (`show
timezone` = `Etc/UTC`; the app writes UTC). Use a timezone-free literal
for the boundary — a `timestamptz` literal silently depends on the
session `TimeZone`:

```sh
TARGET='2026-11-13 11:20:30'        # UTC wall clock, no offset suffix
TARGET_RFC="${TARGET/ /T}Z"         # 2026-11-13T11:20:30Z for Kubernetes

kubectl --context "$KCTX" -n fluxvale-db exec fluxvale-cnpg-1 -- \
  psql -U postgres -d platform_prod -AtF'|' -v target="$TARGET" -c "
select 'organizations',max(created_at) from organizations
union all select 'users',max(created_at) from users
union all select 'instances',max(created_at) from instances
union all select 'memberships',max(created_at) from memberships
union all select 'billing_ledger_entries',max(created_at) from billing_ledger_entries
order by 1;"
```

Pick a target with committed rows on both sides. Sparse tenant tables
are not enough on their own: the newest ledger row here is
2026-11-12T10:00:01Z, so a target the next day would be bracketed by
30 hours. `oban_jobs` inserts every minute and gives a tight probe; the
target above sits between the 11:20:00.343876Z batch and the
11:21:00.361562Z batch. §5.5 proves the stop inside that 60-second
window.

## 4. Isolation envelope (hard rules)

- Restore only into a **local k3d cluster**, in its own namespace
  (`dr-drill`). No `Cluster`, `Job`, or `Secret` is ever created in the
  production or staging namespaces.
- Production access is `kubectl get/exec … psql SELECT` only. No
  scale, patch, apply, or delete against `admin@fluxvale`.
- R2 access is LIST/GET. No `backup`, `prune`, or `delete` command
  touches the bucket.
- The restore `Cluster` has **no `spec.backup` stanza** — it is a
  recovery consumer, not an archiver. Verify no new timeline appears in
  the bucket after promotion (§5.5).
- Tear down the namespace after evidence capture. A leftover scratch
  cluster is both a full data copy and a future no-op trap.

Prose is not a guardrail. Assert the context before creating anything:

```sh
export KCTX=admin@fluxvale
export DRCTX=k3d-fluxvale
[ "$DRCTX" != "$KCTX" ] || { echo "refusing: DRCTX is production"; exit 1; }
kubectl --context "$DRCTX" get --raw=/readyz >/dev/null 2>&1 || {
  echo "refusing: no reachable context $DRCTX"; exit 1; }
kubectl --context "$DRCTX" get nodes -o name | grep -q 'node/k3d-' || {
  echo "refusing: $DRCTX is not the local k3d cluster"; exit 1; }
```

## 5. Restore procedure

Prerequisites: `kubectl`, `aws`, `op` (2.x, for `read -n`), `jq`, and
bash. A local k3d cluster with the CNPG operator installed (match the
production minor — 1.30.x here). Disk: size the PVC from the source
data, not a fixed multiple — 4 GiB was 26× the 152.9 MiB base on
2026-11-13, and will not stay sufficient as the database grows.

### 5.1 Snapshot the live boundary (read-only)

Set `TARGET` once (per §3) and pass it to psql. Do **not** put a second
copy of the instant in a `\set` line; two copies diverge silently.

```sh
TARGET='2026-11-13 11:20:30'

cat > /tmp/dr-verify.sql <<'SQL'
-- Pass the boundary as: psql -v target='2026-11-13 11:20:30'
-- created_at / inserted_at are timestamp WITHOUT time zone; the app writes UTC.
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
         md5(string_agg(id::text||'|'||slug||'|'||name||'|'||created_at::text, E'\n' order by id)) h
    from organizations where created_at <= :'target'
  union all select 'users', count(*),
         md5(string_agg(id::text||'|'||username||'|'||platform_role||'|'||created_at::text, E'\n' order by id))
    from users where created_at <= :'target'
  union all select 'instances', count(*),
         md5(string_agg(id::text||'|'||slug||'|'||name||'|'||status||'|'||coalesce(organization_id::text,'')||'|'||created_at::text, E'\n' order by id))
    from instances where created_at <= :'target'
  union all select 'memberships', count(*),
         md5(string_agg(id::text||'|'||organization_id::text||'|'||user_id::text||'|'||created_at::text, E'\n' order by id))
    from memberships where created_at <= :'target'
  union all select 'billing_ledger_entries', count(*),
         md5(string_agg(id::text||'|'||wallet_id::text||'|'||amount::text||'|'||type||'|'||reason||'|'||created_at::text, E'\n' order by id))
    from billing_ledger_entries where created_at <= :'target'
) s order by t;

select 'boundary', 'last_job_at_or_before', max(inserted_at)::text
  from oban_jobs where inserted_at <= :'target';
select 'boundary', 'first_job_after', coalesce(min(inserted_at)::text, 'none')
  from oban_jobs where inserted_at > :'target';
select 'boundary', 'jobs_after', count(*)::text
  from oban_jobs where inserted_at > :'target';
SQL

kubectl --context "$KCTX" -n fluxvale-db exec -i fluxvale-cnpg-1 -- \
  psql -U postgres -d platform_prod -AtF'|' -v target="$TARGET" -f - \
  < /tmp/dr-verify.sql | tee /tmp/dr-live.txt
```

Record the snapshot wall-clock time next to the output. Run the same
file against the restored cluster in §5.5; only the exec target changes.

### 5.2 Scratch namespace and credentials

```sh
# §4's context assertions must have passed in this shell.
kubectl --context "$DRCTX" create namespace dr-drill
kubectl --context "$DRCTX" -n dr-drill create secret generic r2-creds \
  --from-file=username=/tmp/fv-r2-user \
  --from-file=password=/tmp/fv-r2-pass

# Byte-for-byte check: --from-file must not have gained a newline.
kubectl --context "$DRCTX" -n dr-drill get secret r2-creds \
  -o jsonpath='{.data.username}' | base64 -d | cmp - /tmp/fv-r2-user
kubectl --context "$DRCTX" -n dr-drill get secret r2-creds \
  -o jsonpath='{.data.password}' | base64 -d | cmp - /tmp/fv-r2-pass
rm -f /tmp/fv-r2-user /tmp/fv-r2-pass
```

### 5.3 Apply the recovery cluster

`DEST`, `ENDPOINT`, and `IMAGE` come from production's spec; the heredoc
is unquoted on purpose so the shell substitutes them.

```sh
DEST=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
ENDPOINT=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.backup.barmanObjectStore.endpointURL}')
IMAGE=$(kubectl --context "$KCTX" -n fluxvale-db get cluster fluxvale-cnpg \
  -o jsonpath='{.spec.imageName}')
TARGET_RFC="${TARGET/ /T}Z"

kubectl --context "$DRCTX" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: fluxvale-cnpg-dr
  namespace: dr-drill
spec:
  instances: 1
  imageName: ${IMAGE}
  storage:
    storageClass: local-path
    size: 4Gi
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "${TARGET_RFC}"
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

CNPG 1.30 prints a deprecation warning naming
`spec.externalClusters.0.barmanObjectStore`; expected (§8).

### 5.4 Wait, and record the wall time

```sh
date -u +%FT%TZ
kubectl --context "$DRCTX" -n dr-drill wait \
  --for=condition=Ready cluster/fluxvale-cnpg-dr --timeout=15m
date -u +%FT%TZ
```

`Ready` is the usable state — the instance is promoted
(`pg_is_in_recovery() = false`) and serving. Expect ~3 min for a
153 MiB base plus the WAL replay; scale with database size and the
distance from the target to the nearest base backup.

### 5.5 Verify row-level integrity

```sh
kubectl --context "$DRCTX" -n dr-drill exec -i fluxvale-cnpg-dr-1 -- \
  psql -U postgres -d platform_prod -AtF'|' -v target="$TARGET" -f - \
  < /tmp/dr-verify.sql | tee /tmp/dr-restored.txt

# Counts and checksums must match exactly.
grep -E '^(counts_at_target|checksum)\|' /tmp/dr-live.txt > /tmp/dr-live-cmp.txt
grep -E '^(counts_at_target|checksum)\|' /tmp/dr-restored.txt > /tmp/dr-restored-cmp.txt
diff -u /tmp/dr-live-cmp.txt /tmp/dr-restored-cmp.txt

# The boundary block must show the same last job and no jobs after.
grep '^boundary|' /tmp/dr-restored.txt
```

The `post_target` block is deliberately different when the target is
older than the newest tenant row; on 2026-11-13 it was all zero because
the target was after the last tenant row, and `oban_jobs` carried the
proof instead. Either way, the restored output must never contain a
row the target excluded.

Then confirm the promotion and the absence of an archive:

```sh
kubectl --context "$DRCTX" -n dr-drill exec fluxvale-cnpg-dr-1 -- \
  psql -U postgres -d platform_prod -Atc \
  "select pg_is_in_recovery(), timeline_id from pg_control_checkpoint();"
# expect: f|2

TZ=UTC aws --endpoint-url "$ENDPOINT" s3 ls "$DEST/fluxvale-cnpg/wals/" \
  | grep '^ *PRE 00000002' || echo "no timeline-2 WAL — recovery cluster did not archive"
```

A timeline-2 prefix means the scratch cluster archived; stop and
investigate before the next drill (the manifest must stay
recovery-only).

### 5.6 Teardown

```sh
kubectl --context "$DRCTX" delete namespace dr-drill --wait=true --timeout=5m
kubectl --context "$DRCTX" get namespace dr-drill          # expect NotFound
LEFTOVER=$(kubectl --context "$DRCTX" get pv -o json \
  | jq -r '.items[] | select(.spec.claimRef.namespace=="dr-drill") | .metadata.name')
test -z "$LEFTOVER" || { echo "LEFTOVER PV: $LEFTOVER"; exit 1; }
rm -f /tmp/dr-verify.sql /tmp/dr-live.txt /tmp/dr-restored.txt \
      /tmp/dr-live-cmp.txt /tmp/dr-restored-cmp.txt
```

## 6. Drill record — 2026-11-13

### Restore timeline

| Step | UTC |
|---|---|
| `Cluster` applied | 11:24:03 |
| `Ready=True` (usable) | 11:26:53 |
| **Apply → Ready** | **2m50s** |
| Namespace deleted | 11:27:19 → 11:27:51 (32s) |

The second run was faster than the first (3m03s) on a warm image cache;
treat 3 min as the expectation, not a bound.

### Row integrity (target `2026-11-13T11:20:30Z`)

| Table | Live ≤ target | Restored | Checksum (live = restored) |
|---|---|---|---|
| `organizations` | 3 | 3 | `26f7090a89d6ea4e9226a2fb017e2d2e` |
| `users` | 3 | 3 | `e23b8314678a53beea65dcd312d80a4e` |
| `instances` | 1 | 1 | `dda65c576a81fd0eeda46e3747211dec` |
| `memberships` | 3 | 3 | `b9c217020bbb3317987764016dd2c1ea` |
| `billing_ledger_entries` | 6 | 6 | `d1dd79e01d9f19bf38afb33a584b8729` |

Boundary proof (`oban_jobs` inserts every minute):

| Check | Live | Restored |
|---|---|---|
| Last job `inserted_at <= target` | 2026-11-13T11:20:00.343876 | 2026-11-13T11:20:00.343876 |
| First job `inserted_at > target` | 2026-11-13T11:21:00.361562 | none |
| Jobs after target | 7 | 0 |
| `pg_is_in_recovery()` / timeline | n/a | `f` / `2` |

The stop is therefore bracketed to the 60-second window
`(11:20:00.343876, 11:21:00.361562)`, which contains the target. That is
the achieved precision: the row gap is one minute because that is the
finest write cadence in the database; the drill does not claim an
instant-exact stop.

The latest meaningful rows — the `terenceponce` organization
(`01a1b0ac-3c93-7239-8ccd-9c3e71459e9c`), its user
(`01a1b0ac-3c8d-703c-a8cf-6e39affab9f4`), the `green-dust-3845`
instance (`01a1bde6-b93a-77fa-b5c2-51f9c6675cd6`, memos app,
`sleeping`) and their membership — were present in both. The live
snapshot was taken at 2026-11-13T11:23:43Z.

### Isolation

| Check | Result |
|---|---|
| Scratch Secret vs source | `cmp` clean for both keys — no trailing newline |
| Scratch namespace after teardown | `NotFound`; no PV with claim namespace `dr-drill` |
| Production/staging writes | none — GET/LIST/SELECT only |
| Restore cluster archive | no `spec.backup` stanza; no timeline-2 prefix |

## 7. Delta vs the Thalmyra rehearsal (2026-10-16)

Same toolchain class (CNPG barman PITR into k3d), different cluster and
database:

| | Thalmyra, 2026-10-16 | Platform, 2026-11-13 |
|---|---|---|
| Recovery point | 2026-10-15T12:00Z | 2026-11-13T11:20:30Z |
| Target | local k3d | local k3d, `dr-drill` namespace |
| Apply → healthy | ~3 min | 2m50s |
| Data at target | near-empty tenant — 5 tables, 8 migrations, 0 players | 3 orgs, 3 users, 1 instance, 3 memberships, 6 ledger rows |
| Verification | dump row counts | per-table checksums, live vs restored, plus a 60s PITR bracket on `oban_jobs` |
| Isolation | rehearsal on k3d; the current Thalmyra runbook still restores into `fluxvale-db` on the production cluster and dumps from there | local-only namespace; zero production resources |
| Credential keys | doc says `accessKeyID`/`secretAccessKey` | live Secret keys are `username`/`password` (fv-309 W5) — the Thalmyra copy is stale |

The platform drill is the stricter one: it validates a real row set and
proves the restore stops inside a 60-second window containing the
target, on a target that never touches the shared cluster.

## 8. Findings and owner follow-ups (not changed here)

- **The schedule is hourly, not daily.** The live `ScheduledBackup`
  reports `last=11:03 next=12:03`, and the bucket has 361 base backups
  over 15 days — 24× the intended daily cadence. CNPG's CRD documents
  an extra seconds field, and a five-field expression is interpreted
  seconds-first in practice (`0 3 * * *` = second 0, minute 3, every
  hour). If daily 03:00 was intended, the expression is
  `0 0 3 * * *` (CNPG's documented six-field form). Changing cadence or
  retention changes R2 spend — owner decision.
- **Native barman is deprecated.** The 1.30.x operator's apply warning
  says: “Native support for Barman Cloud backups and recovery is
  deprecated and will be completely removed in CloudNativePG 1.31.0.
  Found usage in: spec.externalClusters.0.barmanObjectStore.” Upstream's
  devel docs now name 1.32.0 instead — the removal target has slipped
  before. Treat 1.31 as the floor and re-check the installed operator's
  warning at upgrade time; migrate to the Barman Cloud Plugin before
  crossing it.
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
- [ ] §3 target recorded, with a tight boundary in a per-minute table.
- [ ] §5.1 live snapshot saved with its wall-clock time.
- [ ] §5.2 Secret `cmp` clean (no newline in either key).
- [ ] §5.4 apply → `Ready` recorded (expect minutes, not tens of minutes).
- [ ] §5.5 counts+checksums diff empty; boundary shows no jobs after.
- [ ] §5.5 timeline 2; no timeline-2 WAL prefix in the bucket.
- [ ] §5.6 namespace gone, no PV, temp files removed.
- [ ] Add a row to the drill log below.

### Drill log

| Date (UTC) | Operator | Target | Apply → Ready | Result |
|---|---|---|---|---|
| 2026-10-16 | Thalmyra rehearsal | 2026-10-15T12:00Z | ~3 min | pass (tenant, near-empty) |
| 2026-11-13 | Terence | 2026-11-13T11:20:30Z | 2m50s | pass (platform_prod, checksums + 60s bracket) |

## Appendix — verbatim evidence

### A. Chain state and objects

```text
$ kubectl --context admin@fluxvale -n fluxvale-db get cluster fluxvale-cnpg -o json | jq …
{
  "phase": "Cluster in healthy state",
  "lastSuccessfulBackup": "2026-11-13T11:03:28Z",
  "lastFailedBackup": "2026-10-02T12:20:50Z",
  "firstRecoverabilityPoint": "2026-10-29T11:55:05Z",
  "conditions": [
    {"type": "ContinuousArchiving", "status": "True", "reason": "ContinuousArchivingSuccess"},
    {"type": "LastBackupSucceeded", "status": "True", "reason": "LastBackupSucceeded"}
  ]
}

$ kubectl --context admin@fluxvale -n fluxvale-db get scheduledbackup fluxvale-cnpg-daily -o jsonpath=…
0 3 * * * last=2026-11-13T11:03:00Z next=2026-11-13T12:03:00Z

$ TZ=UTC aws … s3 ls "$DEST/fluxvale-cnpg/base/20261113T110300/"
2026-11-13 11:03:35       1447 backup.info
2026-11-13 11:03:35  160307200 data.tar

$ TZ=UTC aws … s3 ls "$DEST/fluxvale-cnpg/wals/" --recursive | sort | tail -3
2026-11-13 11:18:30     461629 …/000000010000002F00000097.gz
2026-11-13 11:23:30     231968 …/000000010000002F00000098.gz
2026-11-13 11:28:31     269359 …/000000010000002F00000099.gz

$ TZ=UTC aws … s3 ls "$DEST" --recursive --human-readable --summarize | tail -2
Total Objects: 5952
   Total Size: 43.9 GiB
```

### B. Live snapshot (`TARGET='2026-11-13 11:20:30'`, taken 11:23:43Z)

```text
counts_at_target|billing_ledger_entries|6
counts_at_target|instances|1
counts_at_target|memberships|3
counts_at_target|organizations|3
counts_at_target|users|3
post_target|billing_ledger_entries|0
post_target|instances|0
post_target|memberships|0
post_target|organizations|0
post_target|users|0
checksum|billing_ledger_entries|6|d1dd79e01d9f19bf38afb33a584b8729
checksum|instances|1|dda65c576a81fd0eeda46e3747211dec
checksum|memberships|3|b9c217020bbb3317987764016dd2c1ea
checksum|organizations|3|26f7090a89d6ea4e9226a2fb017e2d2e
checksum|users|3|e23b8314678a53beea65dcd312d80a4e
boundary|last_job_at_or_before|2026-11-13 11:20:00.343876
boundary|first_job_after|2026-11-13 11:21:00.361562
boundary|jobs_after|7
```

### C. Restore apply and wait

```text
restore_start=2026-11-13T11:24:03Z
Warning: Native support for Barman Cloud backups and recovery is deprecated and will be completely removed in CloudNativePG 1.31.0. Found usage in: spec.externalClusters.0.barmanObjectStore. Please migrate existing clusters to the new Barman Cloud Plugin to ensure a smooth transition.
cluster.postgresql.cnpg.io/fluxvale-cnpg-dr created
wait_start=2026-11-13T11:24:03Z
cluster.postgresql.cnpg.io/fluxvale-cnpg-dr condition met
ready_at=2026-11-13T11:26:53Z
```

### D. Restored snapshot and comparison

```text
$ diff -u <(grep -E '^(counts_at_target|checksum)\|' /tmp/dr-live.txt) \
           <(grep -E '^(counts_at_target|checksum)\|' /tmp/dr-restored.txt)
$ echo $?
0

$ grep '^boundary|' /tmp/dr-restored.txt
boundary|last_job_at_or_before|2026-11-13 11:20:00.343876
boundary|first_job_after|none
boundary|jobs_after|0

$ psql … "select pg_is_in_recovery(), timeline_id from pg_control_checkpoint();"
f|2
```

### E. Archive check

```text
$ TZ=UTC aws … s3 ls "$DEST/fluxvale-cnpg/wals/" | grep '^ *PRE 00000002' || echo "no timeline-2 WAL — recovery cluster did not archive"
no timeline-2 WAL — recovery cluster did not archive
```

### F. Teardown

```text
teardown_start=2026-11-13T11:27:19Z
namespace "dr-drill" deleted
teardown_end=2026-11-13T11:27:51Z
Error from server (NotFound): namespaces "dr-drill" not found
leftover_pv=none
```
