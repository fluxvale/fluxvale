# ADR-0027: Admin surface — AshAdmin

**Status**: Accepted
**Date**: 2026-09-01

**Context**: admin surfaces were scattered across ADRs as "small admin
LiveViews" (flags in [ADR-0023](00023-day-one-gates.md), feedback moderation
in [ADR-0026](00026-feedback-board.md)). Review surfaced **AshAdmin**
(`ash-project/ash_admin`): the framework's own extension generating a CRUD
dashboard over Ash resources, built with LiveView. Crucially it runs entirely
**through Ash actions** — policies, validations, and audit hooks apply
automatically — which is the property that disqualifies the alternatives
(a Phoenix LiveDashboard custom page bypasses the action/policy path; a
hand-rolled LiveView rebuilds what the extension generates).

**Decision**:

1. **AshAdmin is the day-one admin surface** for every resource-backed admin
   need: feature flags, access rules, users/wallets/instance inspection,
   feedback moderation. Domains opt in via the admin extension; the
   consolidated record for the per-ADR fragments is here (ADR-0023 Am. 2,
   ADR-0026 Am. 1).
2. **Mounting**: one admin route (`/admin`), admin-gated in prod (route-level
   auth plus the resource policies), open in dev — where it doubles as the
   local flag-flipping surface (no seeding scripts).
3. **Security posture**: exposure is *opt-in per domain*, not blanket.
   Sensitive resources (Identity: User/Token) are excluded unless a concrete
   need appears, and read-only where possible. Mutations ride the same policy
   path as everything else — the admin gate adds no new authorization model.
4. **Actor impersonation** is the standard tool for verifying policy behavior
   live (paying-customer gates, access rules) before test harnesses exist.
5. **Scope rule**: purpose-built admin LiveViews are built only when workflow
   UX outgrows generated CRUD (curated flag view, duplicate-merge moderation
   board — both deferred, not deleted).

**Ops lens trio** (three tools, three jobs, all free/in-stack): **Grafana**
(trend, alerts, everything, from anywhere) · **Phoenix LiveDashboard**
(this node's BEAM, right now) · **AshAdmin** (domain data, act-as-user).

**Meta-lesson codified**: before building any admin-adjacent surface, check
the Ash extension ecosystem first — it is more complete than it looks. (The
hand-rolled LiveView was proposed in this very session before anyone checked.)

**Deferred**: which domains host `FeatureFlag`/`AccessRule` (and thus how
AshAdmin's navigation groups them) is settled with the domain-model cut
(OQ #1).
