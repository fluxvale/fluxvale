# Runbook: block-storage procurement (storage beyond the self-service threshold)

**Internal.** This page carries the vendor, the cost basis, and the fleet ledger. It is
never served: only `docs/public` and `docs/blog` reach the public site
([ADR-0044](../adr/00044-public-docs-surface.md)). No vendor name or cost basis may
appear in member-facing copy — the request UI says only "we order capacity for this" and
the confirmed rate.

Deciding record: [plan 250](../plans/250-storage-approval.md), [ADR-0043](../adr/00043-instance-resize.md)
(storage up-only; capability probe). The issue: #250.

## 1. What and why

Instance storage is self-service up to the ladder's top storage rung — **100 GB** today
(`config :flux_vale, :storage_beyond_threshold, threshold_gb:`; parity-pinned to
`AllocationSliders`). Above that, a member requests a target total and the operator
procures the backing capacity before approving: the approval applies a PVC expansion, and
**storage never shrinks**.

v1 keeps ordering manual. Provisioning automation is explicitly out of scope.

## 2. The capacity pool and the order trigger

Backing capacity is a **shared pool on the box**, carved into instance PVCs by the
expandable StorageClass (TopoLVM, named in #493) — not one dedicated block per request.
That is why beyond-threshold pricing can be per-GB (the COGS per allocated GB is the
pool's €/GB), and why the order trigger is pool headroom, not each request.

Per box:

- local usable capacity: ~460 GB (the renewal-floor RS 4000-class box; the
  [pricing calibration](../pricing-calibration.md) density model);
- attached block storage: **€13/mo per 1 TB, up to 7.6 TB attachable**;
- the pool = local usable + attached blocks (N × 1 TB).

Keep a running ledger (a row per box, updated after every order/attach):

```
box: <name>
local_usable_gb: 460
attached_gb: 0          # N × 1024
allocated_gb: <sum of instance storage_gb on the box>
approved_unapplied_gb: <approved requests not yet applied>
headroom_gb: local_usable + attached - allocated
```

**Order trigger:** when `headroom_gb - approved_unapplied_gb` would fall below the
next block's useful margin (use 1 TB as the increment; order when the projected gap is
under ~1 TB). Order the 1 TB block **before** approving the request that needs it — the
approve action refuses while the StorageClass probe answers false, so an un-attached
order cannot be approved by accident.

The request queue shows each request's current → requested GB and the live capability
probe. Two operators must not approve into the same headroom; the queue is live and the
ledger is the human source of truth.

The queue is the console's **Storage requests** section
(`/admin/storage-requests`). Its sidebar badge counts requests awaiting a decision and
updates live over PubSub on every admin page — no polling, and no email in v1 (production
mail is still the local adapter).

## 3. Order

1. In the provider panel, order **1 × 1 TB block storage** (€13/mo) for the box.
2. Record the order in the ledger (`attached_gb` stays unchanged until attached;
   `approved_unapplied_gb` is the reservation).
3. Wait for the block to appear as a device on the box; do not approve yet.

Above **7.6 TB attachable**, a second box/migration is the answer — out of v1. Reject the
request with feedback ("beyond the capacity we can attach to this instance's host") or
escalate; do not over-promise.

## 4. Attach

**Prod prerequisite (launch checklist, not this lane's build):** the prod StorageClass
must report `allowVolumeExpansion: true` before any beyond-threshold approval can
apply. The k3d patch in §4's local note is a **local-dev enabler only**; a prod
StorageClass change is an owner/operator launch-checklist adjacency — do not improvise it
from a worker branch. The approve action's live probe refuses honestly until it is true.

The exact device/LVM names depend on the box; verify, don't guess. The shape:

1. Attach the new block to the box and confirm the kernel sees it (`lsblk`).
2. Extend the LVM volume group that backs the expandable StorageClass with the new
   physical volume, and grow the thin pool / logical volume (`vgextend`, `lvextend`).
3. Confirm the StorageClass TopoLVM provisions from now reports
   `allowVolumeExpansion: true`:

   ```sh
   kubectl get storageclass <name> -o jsonpath='{.allowVolumeExpansion}'
   ```

4. Canary-check expansion on a throwaway PVC in a scratch namespace (patch the request
   from 1Gi to 2Gi; confirm the spec and the bound volume converge). Delete the scratch
   namespace and class afterwards.
5. Only then approve the queued request. The approval's capability probe is cached for
   5 minutes; if it still answers false, wait out the TTL or verify step 3.

**Local stack note:** k3d's `local-path` class starts without the flag and its expansion
is **spec-level only** — the PVC's requested size changes, the PV's capacity does not, and
the host disk is the real bound. The local enabler is the `local-path-expansion` Tilt
custom deploy in the `Tiltfile`: it patches the class to
`allowVolumeExpansion: true`. Verify with:

```sh
kubectl get storageclass local-path -o jsonpath='{.allowVolumeExpansion}'
```

That makes the local acceptance real at the spec level; it is not a capacity promise.
Production's expandable class is the real gate.

## 5. Approve, verify, reconcile

1. Approve in the console's **Storage requests** section
   (`/admin/storage-requests`). The queue shows the wallet state and the capability
   probe, and approve is disabled with the reason when either blocks. Approve is the
   only path from the ledger to the apply: never edit the request or volume by hand.
2. Verify: the PVC spec grew to the requested total, the instance row's storage moved,
   the allocation era appended, and the ledger's `allocated_gb` moved.
3. The rate re-anchors at approval (create-equivalent snapshot, fresh 1-year clock) and
   includes the beyond-threshold marginal rate. The member sees the applied state and the
   new rate on the instance page.
4. A failed apply leaves the request **Approved** with an error and a Retry button. The
   decision stands; retry after fixing the cluster. Never re-approve.

## 6. Pricing anchor (internal)

- COGS: €13/TB/mo ≈ **1.4¢/GB/mo** in USD at €1 ≈ $1.08 (1.3 euro cents; ≈ $14.04/TB).
- Rule: pass-through + margin as a marginal rate above the threshold; the shipped
  value is `cents_per_gb: 3` (≈ $30/TB), marked **PROVISIONAL** in config until Terence
  ratifies the number in S6. The marginal rate is the configured effective rate for the
  seeded region — a COGS anchor, not a market-curve term, so the v5 surcharge does not
  multiply it.
- One-line home: the `:storage_beyond_threshold` config block (or its seeded equivalent);
  `PriceAllocation.storage_usd_cents/2` is the only pricing seam. Never hardcode a
  business number in code, and never put the vendor or the €13 in member copy.
- The per-GB curve extended is the rejected alternative: $12.80/mo at 1 TB vs $14.04
  COGS, worsening with size.

## 7. Safety

- Storage never shrinks. A request below the current allocation is refused; the queue
  refuses a stale target and tells you to reject.
- Never approve before the capacity is attached and the probe is true.
- Reject with feedback the customer can act on ("we can't attach that much to this
  instance's host") — it is shown verbatim.
- Do not name the vendor, the block size's cost, or the fleet ledger in any UI string,
  screenshot, or public doc.
