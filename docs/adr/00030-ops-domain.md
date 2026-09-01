# ADR-0030: Domain grouping for operator resources — the `Ops` domain

**Status**: Accepted
**Date**: 2026-09-01

**Context**: ADR-0027 deferred "which domains host FeatureFlag/AccessRule"
to the domain-model cut (OQ #1). The pair shares a character no product
resource has: operator-only mutation, platform-wide effect, invisible to
customers, one admin policy. Identity is wrong (flags aren't identity — and
it would split the pair); scattering is wrong (no single policy/admin
surface); `Settings` misleads (implies user settings).

**Decision**:

1. **`FluxVale.Ops`** hosts `FeatureFlag` and `AccessRule` (both from
   [ADR-0023](00023-day-one-gates.md)).
2. It is the **designated growth home for operator-facing resources**:
   audit entries, maintenance windows, announcements — anything with the
   same character joins here rather than leaking into product domains.
3. Product domains stay pure: Identity, Accounts, Catalog, Infrastructure,
   Billing, Feedback carry nothing operator-only. AshAdmin's navigation
   mirrors this — the product domains plus one `Ops` cockpit.

**Resolves**: the deferred item in
[ADR-0027](00027-admin-surface-ashadmin.md); the grouping half of OQ #1
(the inventory itself is assembled across the ADRs; remaining OQ #1 work:
deferral confirmation + build order).
