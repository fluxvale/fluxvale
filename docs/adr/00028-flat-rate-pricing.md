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
5. Welcome credits, Dodo checkout, and wallet mechanics are unaffected.

**Amends**: [ADR-00005](00005-customer-instances-as-namespaces.md)
(settle_usage semantics); [product.md](../product.md) business model.
