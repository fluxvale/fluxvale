# ADR-00028: Pricing — allocation-based flat monthly rates, not measured usage

**Status**: Accepted
**Date**: 2026-09-01

**Context**: v1's model (and v2's initial carry-over) metered actual usage
per second (CPU/RAM/storage hours against measured consumption). The
proven model in this category instead shows the customer a **simple monthly
price per instance** derived from its allocation, and charges that flat
rate regardless of actual usage. Trade-off accepted deliberately:
predictability and a radically simpler mental model ("Kavita: $X/mo, done")
beat metered fairness for a zero-ops audience — and usage-measurement
correctness stops being a billing liability entirely (billing becomes
arithmetic on time and allocation).

**Decision**:

1. **Price = f(allocation)**: an instance's cpu/ram/storage size determines
   a flat monthly rate, shown live in the catalog/instance UI ("$X.XX/mo").
   Calibration (sum of flat prices at target density vs the €21.61/mo box
   COGS, with margin) is a launch-gate sanity check (OQ #2).
2. **Running = flat rate; stopped = storage-only flat fee** — same anchor
   semantics as before, simpler math. Auto-sleep's pitch shifts to "pause
   it and it costs almost nothing."
3. **The settlement machinery is unchanged**: wallet, append-only ledger,
   idempotency keys, advisory locks, metering anchors, and the
   `settle_usage` job all survive — they now accrue the flat rate over
   elapsed time ([ADR-00005](00005-customer-instances-as-namespaces.md)
   Am. 1).
4. **Usage telemetry returns to observability-only**: PromEx/Traefik/metrics
   feed SLIs and dashboards ([ADR-0012](00012-observability-grafana-cloud.md)
   Am. 3), never the ledger.
5. Welcome credits, wallet mechanics, and payment checkout (adapter + HitPay per [ADR-0029](00029-payments-adapter-selfmor.md) Am. 2) are unaffected.

## Amendment 1 — custom allocations price by the anchor formula (2026-10-21)

User-choosable allocation (#180) needed semantics for allocations that
match no seeded size. Decided on #186 (the "continuous formula" option;
the alternative, snapping custom allocations to the nearest seeded
size, was rejected for its price steps): **the market-anchor curve
itself is the price function** —
`FluxVale.Pricing.price_allocation/1` evaluates it at any floor-legal
allocation (coefficients and rounding in
[pricing-calibration.md](../pricing-calibration.md); the calibration
tests pin the seeded table to it exactly). A custom allocation
snapshots the formula's cents at create with #121's 1-year grace and
reprices from the live curve after; an at-recommendation instance
keeps snapshotting its Size row — the paths agree at size points.
Revisit trigger: an anchor re-version (v5) or per-app price modifiers,
either of which makes "one global curve" too coarse.

**Amends**: [ADR-00005](00005-customer-instances-as-namespaces.md)
(settle_usage semantics); [product.md](../product.md) business model.

## Amendment 2 — curve v5: regional surcharges on the anchor (2026-10-22)

The #200 renewal-cost recalibration (owner decision: **B′ ×1.2**)
re-priced the curve without changing its shape: v5 = the v4 curve × a
per-region surcharge (`PriceAllocation`'s multiplier map —
`:nuremberg` 1.2 shipped; `:singapore` 1.25 decided but on standby,
unseeded until the SG box exists). Pricing is per-datencenter
([pricing-recalibration-2026-10.md](../pricing-recalibration-2026-10.md)):
a region's floor rides its own multiplier, never a second curve.
Activation gate: charging at B′ presumes the scale-to-zero lane —
the density economics assume sleeping instances. Display framing
(#206): every customer-facing price states monthly-equivalent ·
billed hourly (µs accrual — Decision §3 here,
[ADR-0005](00005-customer-instances-as-namespaces.md) Am. 1).

**Amends**: the calibration basis of Decision §1
([pricing-calibration.md](../pricing-calibration.md) now carries the
B′ table).
