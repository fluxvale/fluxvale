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
   **3¢/GB/mo, ratified 2026-11-10** (COGS floor ≈ 1.4¢/GB at €13/TB ≈
   $14.04; Amendment 1 records the payment-fee basis and the $5 wallet
   floor ratified with it). Member copy
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

## Relationship to prior ADRs

- **Amends [ADR-0043](00043-instance-resize.md)'s storage arm.** The
  up-only ruling and the live capability probe stand. The stopped-first
  fence does **not** apply to an approved storage-only growth, which is
  online. #243 narrows to CPU/RAM once this lands; self-service storage
  keeps flowing through resize until that decision is taken.
- **Amends [ADR-0028](00028-flat-rate-pricing.md)'s pricing.** The anchor
  curve remains the price function up to the threshold; above it the
  configured marginal rate stacks on the curve's threshold price — a COGS
  pass-through + margin, not a curve term.

## Amendment 1 — the rate is ratified (2026-11-10)

**S6 closes #250: `cents_per_gb: 3` stands, and the wallet top-up minimum
moves from $1 to $5** (`config :flux_vale, :billing, min_topup_cents: 500`).

The ratification basis is the fee under every dollar of this revenue.
Revenue arrives through the prepaid wallet, so the gateway fee rides the
**top-up**, not the monthly storage charge — `Billing.Providers.Polar`
charges the checkout and hourly usage debits the wallet. On Polar Pro
(**3.8% + $0.40 per checkout, $20/mo**) the fee is therefore
`3.8% + $0.40/T` per dollar of spend (T = top-up dollars):

| top-up T | fee share of spend | net ¢/GB | gross margin |
|---|---|---|---|
| $1 (the old floor) | 43.8% | 0.282 | 9.4% |
| $5 (ratified floor) | 11.8% | 1.242 | 41.4% |
| $10 | 7.8% | 1.362 | 45.4% |
| $20 | 5.8% | 1.422 | 47.4% |
| $50 | 4.6% | 1.458 | 48.6% |
| ∞ (variable only) | 3.8% | 1.482 | 49.4% |

Overage size does not move those rows: the rate is a fixed ¢/GB, so the
fixed fee's ¢/GB cost tracks the dollar value of the charge, and only the
top-up size sets its share.

Two consequences are decisions, not accidents:

1. **3¢ keeps its no-fee story only as a headline.** The 3.8% variable
   alone caps the marginal gross at 49.4%; realistic top-ups ($20–30 — the
   mode from the ladder's plus/pro bills) land 47–48%. The owner accepted
   that trim: the rate is the product's cost story, not a fee passthrough.
2. **The $5 floor is the fee's control.** $10 would have held 45.4% and
   $5 holds 41.4%; the owner chose $5 over $10 for lower early-stage
   friction and accepted the 41.4% floor. `StartTopup` refuses a smaller
   top-up (`:amount_below_minimum`), so the floor is a rule rather than a
   UI hint; the wizard, its copy, and the paid-feature prompts read the
   one config value.

Holding the 53% headline instead would have needed **3.25¢/GB at a $10
floor, 3.17¢ at $25, and 3.13¢ as the hard floor** (the variable fee costs
0.114¢/GB); **4¢** would have over-earned at 57–60%. The $20/mo Pro line
is fixed overhead, not per GB: $0.20/customer at 100 customers, or about
14 beyond-threshold customers' marginal storage margin. The fee schedule
is a plan term, so a provider change re-runs the same table.
