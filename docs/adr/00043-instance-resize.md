# ADR-0043: Instance resize

**Status**: Accepted
**Date**: 2026-11-06

## Context

Allocation is user-choosable at create
([ADR-0028](00028-flat-rate-pricing.md) Am. 1)
but frozen afterwards: changing an instance's size means destroy and
recreate — data goes with it. #493 asks for in-place resizing. The
owner settled the rulings on the issue: CPU and RAM move both ways,
storage only grows, the apply happens stopped-first, and a resize
prices like a fresh create with a fresh 1-year grandfather clock.

## Decision

### Stopped-first

`resize` refuses anything not `:stopped` ("cannot resize instance in
running state (must be stopped)") — it never defers or auto-stops. The
cluster re-apply lands while stopped: the Deployment re-applies with
replicas following the live claim — 0 while stopped (the pod template
rolls with no pod churn), and the workload runs at the new size on
next start; a racing start's scale-to-one is preserved (the template
rolls at the new size and the start completes honestly). This keeps the
metering story trivial — the open interval is settled at the OLD rate
inside the action's transaction before the row flips, so no hour
straddles two prices; the settled amount and the flip commit or roll
back together. The re-apply's env_from_secret decision reads the
cluster's app-env Secret rather than recomputing deploy's env (which is
exposure-dependent and deploy-time-frozen) — what the pod already
references is what the re-apply keeps, so a seeded ROOT_URL can never
be stripped by a resize.

Racing resizes refuse the slower one (`optimistic_lock(:version)`, the
`set_exposure` precedent). A concurrent `start`/`delete` bumps no
version, so the resize's settle re-reads the row FOR UPDATE inside the
transaction and re-checks the status there — the row lock holds until
the resize commits, making the stopped-first check airtight at write
time.

The resize's transaction holds the org's wallet advisory lock across
the cluster applies (the settle-before-flip shares the settle's
transaction). Accepted trade-off: settles are idempotent Oban cron — a
concurrent settle waits out the applies, then proceeds; delay, never
loss. The alternative (applying past commit) breaks the retry story, so
the lock stays. Revisit trigger: if an org's settle lane ever shows
lock stalls, move the apply past commit behind a converge-on-retry
verb.

### Create-equivalent re-pricing

The resize prices through `Instance.PricingSnapshot.snapshot/3` — the
one choice the create's derive also calls — so resize cents are
identical to destroy-and-recreate **by construction**: at the version's
recommendation the recommended Size row snapshots (its CURRENT cents);
any dimension off prices by the live anchor formula, no size; a
sizeless recommendation stays unpriced (billing never guesses). The
old grandfather clock dies with the old allocation; the new one runs
`resize instant + 1 year`. A conscious edge: resizing back to a
sizeless version's recommendation mirrors create exactly — the era
goes unpriced and settlement skips it loudly, identical to
destroy-and-recreate on that drift shape (accepted per the
create-equivalence ruling).

### Append-only allocation-era trail

Every instance carries an append-only audit trail
(`instance_allocation_snapshots`): one row per allocation era — the
allocation, the size and cents that priced it, `effective_from`, and
`superseded_at` (nil = in force; a partial unique index holds "at most
one open era per instance"). Era 1 mints on create; a resize supersedes
the open era and appends the new one, both inside the action's
transaction. The instance row stays the live read path for settlement
and the runway projection — the trail is history, not a second billing
input (the PVC mint-vs-upsert decision compares the pre-resize row
value the action passes; it never reads the trail). Pre-#493 rows
backfill one era from their create-time values — dev/staging
completeness only: pre-launch data is wiped at launch, so no migration
is owed (owner ruling).

### Storage: up-only, capability-gated

Storage never shrinks — PVC shrink is not a thing Kubernetes allows,
and a refused grow with both figures named beats silent data loss.
Growth is gated on a LIVE probe of the cluster's default StorageClass
(`allowVolumeExpansion`), cached per cluster for 5 minutes: expansion
is the storage layer's capability, not a platform promise — local-path
answers false today, and when the storage lane ships an expandable
class (TopoLVM, named in #493), the policy self-unlocks inside the TTL.
No flag, no app change. Probe errors fail the resize honestly — the
platform never bills a capability it couldn't read, and the copy
distinguishes a failed check ("try again") from the capability no. The
0→N crossing on a file-access app additionally mints the WebDAV
sidecar's world — credential Secret (get-or-create; a retrying resize
never rotates the owner's credential), DAV Service, and edge arms —
exactly what a deploy at N GB would have minted.

### Wire and policy

The resize rides the member surface like start: membership AND a
funded wallet (#124 — resize changes burn like a fresh start), same
`instances:write` PAT scope. No publish in this slice (status never
changes); the resize panel lands with the UI slice and re-reads on its
own submit response.

## Rejected alternatives

- **Defer storage to the storage lane**: ships no policy day one, and
  the up-only ruling needs its gate now; the probe seam makes the
  future expandable class a no-op unlock.
- **Allow shrinking**: never (owner ruling) — a shrink would orphan
  data or require a destructive migration per instance.
- **Live resize** (apply while running, roll the pod): out of scope for
  #493 — it buys zero-downtime at the cost of a second apply path,
  in-flight pricing straddles, and a much wider blast radius. Revisit
  only if stopped-first's restart cost proves material in practice.

**Amends**: [ADR-0028](00028-flat-rate-pricing.md)
Am. 1's "snapshots at create" reading — allocation eras snapshot at
create AND at every resize, through the same snapshot choice.

## Amendment 1 (2026-11-07)

The UI slice adds `publish(:resize, ["instances", :id])`: an open
panel in another tab resets when another writer resizes the row (the
seed-mismatch rule), which no status change would carry — the resize
still never moves status. Supersedes this ADR's "Wire and policy"
line that no publish rides the action.
