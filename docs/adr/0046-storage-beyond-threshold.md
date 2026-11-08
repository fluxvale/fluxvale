# ADR-0046: Storage beyond the self-service threshold — request, operator approval, online growth

**Status**: Accepted
**Date**: 2026-11-09

**Context**: The storage ladder stops at its top rung — **100 GB**
(self-service; the larger #233 rungs were rejected on #399). Issue #250's
Oct 24 product decision: storage requests are not capped by the ladder,
but capacity the box does not already hold needs procurement, so requests
above the boundary flow through an operator approval queue — request from
the instance page, queue + notification, operator orders capacity,
approval grows the volume. The full implementation contract is the
[plan](../plans/250-storage-approval.md); the internal order path is the
[block-storage runbook](../runbooks/block-storage.md).

[ADR-0043](00043-instance-resize.md) owns the storage mechanics (PVC
growth, the live `allowVolumeExpansion` probe, settle-before-flip), but
its apply is stopped-first — a full re-apply for CPU/RAM. An approved
storage request is a different shape: storage only, and it should not
wait for the customer to stop the instance.

## Decision

1. **The boundary is configuration, never a code constant.** One block:
   `config :flux_vale, :storage_beyond_threshold` with `threshold_gb: 100`,
   `cents_per_gb: 3`, `max_gb: 7_600`. The value is a map —
   `%{threshold_gb:, cents_per_gb:, max_gb:}` — and `PriceAllocation`
   pattern-matches it, so a missing or malformed key fails loudly instead
   of mispricing. A test pins `threshold_gb` to
   `FluxValeWeb.AllocationSliders.storage_dimension()`'s top rung, so a
   future ladder move is a reviewed two-line change, never a silent fork.
   `max_gb` is the attachable ceiling (7.6 TB), not a ladder value.
2. **Marginal overage pricing = pass-through + margin.**
   `PriceAllocation.storage_cents/2` prices the first `threshold_gb` on
   the existing v5 curve exactly as below it (100 GB = 228¢); each GB
   above bills at `cents_per_gb`. The marginal rate is the seeded
   region's effective COGS pass-through plus margin — not a market-curve
   term — so the v5 regional surcharge never multiplies it. The number is
   **PROVISIONAL 3¢/GB/mo** (COGS floor ≈ 1.4¢/GB at €13/TB ≈ $14.04);
   the owner's one-line ratification is S6, #250's closer. Member copy
   stays rate-agnostic: it shows the computed monthly figure, never the
   per-GB rate, the COGS, or the rule
   ([pricing calibration](../pricing-calibration.md)).
3. **An operator approval queue is the procurement gate.** A member
   submits a target total (not a delta) with a reason; the request moves
   `requested → approved → applied`, and `rejected` (feedback required,
   shown verbatim to the member) is terminal. Approve is a durable
   decision followed by a retryable apply: a failed volume patch leaves
   the request `approved` with an error and a retry, never a lost
   decision. One open request per instance (partial unique index).
   Ordering stays manual in v1. Notification is PubSub (sidebar badge +
   live queue), not email — production mail is a local placeholder, so an
   operator email would be a silent no-op.
4. **Approved growth is online and storage-only.** The apply settles the
   open usage interval at the old rate, re-prices through
   `Instance.PricingSnapshot.snapshot/3` (create-equivalent, fresh
   1-year clock), appends the allocation era, and patches the PVC +
   storage quota. No stopped-first fence: that ruling belongs to the full
   CPU/RAM re-apply, which this path deliberately does not do. A 0→N
   file-access crossing re-applies the Deployment for the WebDAV sidecar;
   a normal grow does not roll the pod (a restart may be needed to see
   the new space — stated in the approve copy). Storage still never
   shrinks.
5. **Production prerequisite: the default StorageClass must set
   `allowVolumeExpansion: true`.** The approve action refuses honestly
   until the live probe answers true. The k3d patch is a **local-dev
   enabler only** (local-path growth is spec-level; the host disk is the
   real bound). A production class change is a launch-checklist
   adjacency the owner/operator owns — never improvised in this lane.

## Rejected alternatives

- **Extend the per-GB curve** (the pre-#250 reading). The v5 curve is
  underwater at 1 TB ($12.80/mo vs ≈ $14.04 COGS) and the gap widens — 2 TB
  $21.53 vs $28.08; 7.6 TB $58.61 vs $106.70. It cannot cover the
  procurement it triggers.
- **Reuse the stopped-first resize** for approved growth. It turns a
  two-party workflow (member asks, operator procures) into a three-party
  chase (wait for the member to stop). The fence stays where it belongs:
  the full re-apply.
- **A dedicated block per request.** Backing capacity is a shared pool on
  the box, carved into instance PVCs by the expandable class — per-GB
  pass-through is economically sound, and the runbook's order trigger is
  pool headroom, not each request.
- **Hardcode 100 / the rate in code.** The issue's original 400 GB
  boundary was wrong (the ladder stops at 100); configuration plus the
  parity test keeps the boundary honest, and the rate is the owner's
  number, not a code default.
- **Operator email in v1.** Production cannot deliver mail yet; revisit
  when the production mailer lands (the recorded trigger).

## Amendment relationship

- **Amends [ADR-0043](00043-instance-resize.md)'s storage arm.** The
  up-only ruling and the live capability probe stand. The stopped-first
  fence does **not** apply to an approved storage-only growth, which is
  online. #243 narrows to CPU/RAM once this lands; self-service storage
  keeps flowing through resize until that decision is taken.
- **Amends [ADR-0028](00028-flat-rate-pricing.md)'s pricing.** The anchor
  curve remains the price function up to the threshold; above it the
  configured marginal rate stacks on the curve's threshold price — a COGS
  pass-through + margin, not a curve term.
