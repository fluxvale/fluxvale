# ADR-0050: Operational console — curated at-a-glance, linked-not-embedded

**Status**: Accepted (owner go Nov 11, 2026, #702 — the gate calls are recorded in the plan)
**Date**: 2026-11-11

**Context**: the admin console ([ADR-0027](00027-admin-surface-ashadmin.md)
Am. 3/4) is a daily tool built of sidebar sections, but operational
state — fleet health, smoke verdicts, wake latency, storage posture,
recent activity — lives only in Grafana (and soon PostHog), a context
switch away from the product. The obvious shortcut, embedding
Grafana/PostHog dashboards in the admin surface, was evaluated and
rejected before this ADR: Grafana iframe auth is viewer-token theater,
PostHog has no white-label embedding, and slicing shared third-party
projects per tenant is an isolation nightmare. The owner approved the
opposite shape Nov 11, 2026: FluxVale's own at-a-glance surface.

**Decision**:

1. **Console-not-dashboards.** A `/admin/health` sidebar section of
   curated widgets — state, health, recent activity, trends. No funnel
   builders, no ad-hoc query UI, no log search, no chart editor. The
   full widget contract (every widget, its data source, its exact
   read) is the plan (#702,
   [plans/702-operational-console.md](../plans/702-operational-console.md)).
2. **Linked-not-embedded.** Grafana and PostHog remain the deep-dive
   tools; the console deep-links to them and never embeds them. This
   is the boundary at the UI layer — and decision 4 is the same
   boundary at the API layer.
3. **No widget without a real source.** Every widget reads a named,
   existing source (a resource read, a paper-trail table, the in-process
   metrics tree, or a public API) and states its window honestly (the
   wake numbers are in-memory and say "since this deployment
   started"). Where no source exists yet — error counts until the
   PostHog split (ADR-0049, Proposed) flips, synthetic verdicts which
   have no in-app seam — the slot says so in place (the console's
   Coming grammar) and never fabricates a number.
4. **Third-party reads are server-side, fixed, and cached.** The
   Tier-2 proxies (PostHog insights, Grafana hosted Prometheus) serve
   a whitelist of named queries only — a proxy that forwards
   arbitrary queries is a dashboard suite by another door. Tokens
   live only in server env sourced from 1Password
   ([ADR-0021](00021-secrets-bws-operator.md) Am. 3) and never reach
   the browser; every upstream call caches 30–60s; free-tier rate
   limits are respected by construction (a handful of named queries
   a minute). Design only in this lane — its own gate after Tier 1;
   the PostHog leg is additionally deferred to ride the split's
   S1/S4 landing (owner call at the gate, Nov 11, 2026).
5. **Platform-admin-only.** The section rides the admin gate stack
   (Am. 3's triple gate plus Am. 5/6's demotion seams) and reads with
   the admin actor through resource policies
   ([ADR-0047](00047-platform-admin-authority.md)); no new
   authorization model, no member visibility.
6. **The error-count seam is reserved, not blocked on.** The snapshot
   carries an errors section that answers "not configured" until the
   PostHog split's S1/S4 land; then it is populated through the
   Tier-2 read proxy. The console never blocks on an unbuilt source
   and never pretends to have one.

## Rejected alternatives

- **Embedding Grafana/PostHog** — weak iframe auth; no white-label
  PostHog; shared-project slicing is a multi-tenant isolation
  nightmare. Dead before proposal, recorded so it stays dead.
- **A dashboard suite** — Grafana already is one, free, and good;
  the console's job is triage at a glance, Grafana's is
  investigation. Building funnels/queries/log-search duplicates the
  tool we already pay for with our own maintenance.
- **A capacity-pool ledger resource now** — the runbook
  ([runbooks/block-storage.md](../runbooks/block-storage.md)) is the
  deliberate human source of truth for pool headroom; the widget
  shows the platform-side facts (allocated, queued) and points at
  the runbook. A ledger resource is a real decision for a real
  volume, not a console slice.
- **Cross-env fleet views in v1** — staging and prod are separate
  databases by construction; the console is per-environment and says
  so (the env label). Cross-env federation would need the other
  env's HTTP surface — deferred until it earns itself.
- **Wake p95 only in Grafana** — `FluxVale.Observability.WakeStats`
  already reads the exact series in-process; extending it to p95 is
  cheap and keeps the user-facing number and the SLO dashboard on
  one source.
- **LiveDashboard as the home for these widgets** — per-node BEAM
  introspection, not fleet/business state; Am. 3 already assigned it
  the debug role at `/admin/debug/dashboard`.

## Relationship to prior ADRs

- [ADR-0027](00027-admin-surface-ashadmin.md) Am. 3/4: the console
  section pattern this follows (sidebar entry, section LiveView,
  same gate stack).
- [ADR-0047](00047-platform-admin-authority.md): the admin actor and
  the blanket-authority bypass every read here rides.
- [ADR-0048](00048-ash-paper-trail-audit.md): the version tables the
  fleet-deploy and audit-activity widgets read.
- ADR-0012 as amended, and ADR-0049 (Proposed, in flight): the
  observability stack the console summarizes and links into; the
  error widget's future source.
- #232 (wake SLO), [ADR-0046](0046-storage-beyond-threshold.md)
  (#250's queue): the widget subjects.
