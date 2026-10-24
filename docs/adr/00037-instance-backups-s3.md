# ADR-0037: Instance backups — restic to BYO S3-compatible storage (R2 first)

**Status**: Accepted
**Date**: 2026-10-23
**Issue**: #222 (owner's dogfood gate #165 — his Forgejo + Kavita
instances backing up to his Cloudflare R2 bucket)

## Context

Instances are k8s namespaces with a PVC ([ADR-0005](00005-customer-instances-as-namespaces.md));
the platform runs the lifecycle, the user owns the data. Until now the
only copy of that data was the PVC itself — the fleet's WAL-G → R2
backups cover platform DBs, not customer volumes. #222's ask, exactly
in PikaPods' shape: the user supplies S3-compatible keys (R2 first),
the platform backs the instance up there on a schedule, shows status,
and can restore. BYO bucket means storage costs sit with the user —
v1 charges nothing extra, and the user's keys serve nothing but their
own backups.

This ADR owns the four decisions the issue names: engine, consistency
stance, scheduling model, restore shape.

## Decision

### 1. Engine: restic (rejected: rclone sync, tar+upload)

A backup Job in the instance namespace runs the pinned stock image
`restic/restic:0.19.1` against the user's bucket, mounting the PVC.

- **Backups are snapshots, not mirrors.** `rclone sync` (the #190
  sidecar's tool, tempting for image reuse) propagates the current
  state: corrupt or delete a file on the volume, sync faithfully
  destroys the last good copy in the bucket. Sync is an availability
  tool; versioned snapshots are the product requirement ("keep N",
  restore a point in time).
- **Dedup respects the user's bucket.** A daily full tar of a 10 GB
  Kavita library is ~70 GB/week of redundant storage the user pays
  for. restic's content-addressed chunks send only what changed —
  and subsequent runs are minutes, not re-uploads.
- **Client-side encryption is free and mandatory.** restic encrypts
  the repo before it leaves the job; the bucket alone never holds
  plaintext. We must manage a repo password either way (restic
  requires one) — see §4.
- **Retention and restore are built in**: `restic forget --keep-last
  N --prune` and `restic restore <id> --target` are the whole of
  those features; tar+upload would hand-roll both (and put plaintext
  tars in the bucket).

The restic repo is single-writer (locks); we run at most one Job per
instance at a time (the sweep guards it, §3). rclone stays the
file-access sidecar — different job, [ADR-0035](00035-per-instance-file-access.md).

### 2. Consistency: crash-consistent PVC snapshot, documented caveat (rejected for v1: pre-backup hooks)

The backup copies the PVC as-is, without quiescing the app.

Scoped to the two apps that gate dogfooding: **Forgejo** is git bare
repos (append-only object files — a torn copy is fsck-recoverable)
plus a small SQLite metadata db; **Kavita** is static media plus a
small SQLite library db. Both are single-user instances with low
write rates, and the default window (§3) is off-peak for the fleet
(NetCup, EU). A torn SQLite catch is possible but rare at these write
rates — and non-fatal: retention keeps N snapshots, so a bad one
doesn't destroy history; restore falls back to the previous
snapshot. The instance page's backup panel says so in plain words
(snapshots are taken while the app runs; database-backed apps may
rarely need the previous snapshot).

Rejected for v1: pre-backup hooks. `forgejo dump` duplicates the
volume into a zip inside the volume (double storage, double backup);
an app-agnostic `sqlite3 .backup` pass needs sqlite3 in the job image
and per-app db discovery — magic that only pays off with a catalog
that declares it. The amendment path is additive when a customer app
demands it: catalog `backup` metadata (paths, dump command) snapshot
onto the Instance, exactly the `file_access` pattern
([ADR-0035](00035-per-instance-file-access.md)). PikaPods — the shape
the owner asked for — ships un-quiesced scheduled copies.

### 3. Scheduling: platform-side Oban sweep creating k8s Jobs (rejected: per-namespace CronJob, in-pod agent)

All scheduling in this repo is Oban; that stays. A `BackupSweep`
worker (queue `:backups`, every 5 min, offset off the top per the
#113 stance) does two passes:

- **Due pass**: instances with backups enabled whose daily window has
  passed and have no run since it opened, and no active run → create
  a `BackupRun` row, apply the k8s Job. Manual "Back up now" creates
  the same row + Job immediately — one code path.
- **Watch pass**: active runs → read the Job's status → finalize.

v1 schedule shape: **daily at 03:00 UTC plus per-instance minute
jitter** (id-derived, spreads fleet load). The user controls enabled
and retention, not the clock; a per-instance cron picker is a later
knob if anyone asks for it. A missed window (platform down) is caught
up by the next sweep the same day.

The Job: env-from the `backup-config` Secret (§4) carrying
`RESTIC_REPOSITORY` (composed by the platform from endpoint/bucket/
prefix), `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`; `RESTIC_HOSTNAME` pinned to the instance
slug (pod names are random — unpinned hostnames fragment restic's
grouping and retention); `restic backup <mount> --json`, then
`restic forget --keep-last N --prune` in the same run (a repo that
can't prune is unhealthy — the run fails). The job script writes
restic's summary JSON to `/dev/termination-log`: the platform reads
snapshot id and bytes from `job.status.containerStatuses` — the
termination-message side channel, no pod-log scraping, no secrets
ever in logs.

Rejected: a per-namespace **CronJob** (forks the scheduling model,
needs its own RBAC/lifecycle choreography, and the platform still
couldn't see outcomes without watching). Rejected: an **in-pod agent
sidecar** (couples backups to instance lifecycle — an asleep instance
is the *best* backup moment, PVC present and no writers
([ADR-0036](00036-scale-to-zero-wake-on-use.md)); a stock restic image
can't take commands without exec plumbing).

RWO note: the cluster is single-node today, so the Job trivially
co-locates with the app pod. Node #2 forces the storage decision
already open in [architecture.md](../architecture.md) — that decision
must account for backup Jobs (RWX or node pinning). Revisit trigger
sits there, not here.

**Quota**: the Job runs inside the instance namespace, so its requests
must be inside the ResourceQuota — enabling backups widens the quota
by the Job's requests (the #190 sidecar's arithmetic), and
DeployInstance re-applies with that margin when backups are on.
Egress is already open (M3 stance), so R2/MinIO reach needs no
NetworkPolicy change.

### 4. Credentials: the `backup-config` namespace Secret (ADR-0035's stance, extended)

- **DB** (`BackupSetting` row): endpoint, bucket, prefix, retention,
  enabled, and the **access key id** — an identifier, not a
  credential (it authenticizes nothing without the secret); it gives
  the settings UI honest masked confirmation ("…K4F2").
- **Namespace Secret `backup-config` only**: the **secret access
  key** and the **restic repo password** — generated once at enable
  (32-byte CSPRNG URL-safe, the `RCLONE_PASS` recipe), get-or-created
  across saves so a retry never rotates it. Rotation invalidates
  every existing backup, so it never happens silently. The platform
  DB stores neither, ever — same three reasons as ADR-0035's "the
  namespace Secret, not BWS", plus the issue's own fence: the user's
  keys serve nothing but their own backups.

The repo password gets a reveal + copy affordance (no-wrap,
exact-string copy — ADR-0035 Am. 1's lessons) with loud copy: **it
is required to restore into a new instance after this one is
deleted**, because the Secret dies with the namespace. Not derived
from the S3 secret key — key rotation would silently brick old
repos; explicit beats clever.

### 5. Restore: same-instance, scale-down first (stretch not shipped: restore-to-new-instance)

v1 ships restore-back-into-the-same-instance only — the feature's
other half; restore-to-new needs a user-supplied repo password at
restore time (the §4 copy is the seed of that flow) and is the
natural next slice, not this one.

Flow: guard (settings + ≥1 successful run) → status `:restoring`
→ scale the Deployment to 0 if running (`StopInstance` mechanics;
sleeping/stopped rows are already at 0, and the wake endpoint's
other-status arm 503s instead of waking — restore owns the instance
exclusively; `StartInstance`'s status guard no-ops; the reconciler's
trigger only selects `[:deploying, :starting, :running]`) → restore
Job (`restic restore latest --target <mount>`) → on success scale
back to 1 → `:starting` → the reconciler lands `:running` (or return
to the pre-restore state without waking) → on failure `:error` with
a new `:restore_failed` reason. Restore overwrites current data; the
UI confirms in plain words.

`BackupRun` carries the history for both directions (`kind`
scheduled | manual | restore), so the panel shows one timeline.

## Consequences

- Teardown tolerantly deletes `backup-config` and any backup Jobs
  with the namespace (`:not_found` = success — pre-#222 namespaces
  never had them); the bucket and its contents are the user's.
- Local stack gains an in-cluster MinIO (`deploy/local/k8s/`, chart
  -free single manifest) as the R2 proxy — no real credentials in CI
  or e2e, ever. The Tiltfile parity ledger's "no backups" line flips.
- Instance backups and instance health stay separate axes: a failed
  backup never flips `Instance.status`; it surfaces on the backups
  panel (warning tone + the run's sanitized summary, ≤500 chars).
- Catalog apps need no changes in v1 — the whole PVC at the
  Instance's `storage_mount_path` snapshot is the backup set.
- Product docs note: BYO bucket means the user pays their provider
  for storage; FluxVale charges nothing extra for the feature.

## Amendment 1 (2026-10-24): two mechanism corrections from implementation

The execution slice landed against the pinned `restic/restic:0.19.1`
and proved two §3 details wrong as written:

1. **The hostname env var is `RESTIC_HOST`, not `RESTIC_HOSTNAME`.**
   restic (0.19.1 source, `doc/075_scripting.rst`) documents no
   `RESTIC_HOSTNAME`; an unpinned host would have silently used the
   random pod name — exactly the fragmentation §3 warns about. The
   Job pins `RESTIC_HOST` to the instance slug; §3's intent stands,
   its variable name was wrong.
2. **The termination message is a Pod field, not `Job.status`.**
   `JobStatus` carries no `containerStatuses`; the aggregate verdict
   lives on the Job (`status.succeeded`/`failed` + conditions) and
   the one-line outcome JSON lands on the Job's **pod**
   (`status.containerStatuses[].state.terminated.message`). The
   platform reads the Job's verdict, then the pod's message only
   once the verdict has settled. Same side channel, correct object.
