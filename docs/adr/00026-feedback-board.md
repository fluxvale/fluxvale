# ADR-0026: Feedback board — in-app, publicly readable, paying-customers-write

**Status**: Accepted (amended — see Amendment 1)
**Date**: 2026-09-01

**Context**: a public feedback board (feature requests + upvotes + comments,
with a status workflow) is a proven community surface for this product
category. The write-gate requirement is the load-bearing one: **viewable by
the public, but commenting and voting restricted to paying customers.**

**Rejected — external/self-hosted feedback-portal platforms** (the kind other
small hosts run on a subdomain): they cannot see FluxVale's wallet ledger,
so the paying-customer gate is unenforceable. Enforcing it would require
making FluxVale an OAuth *provider* (machinery we deliberately don't run) and
still couldn't convey the paying flag actionably. They also split SEO onto a
subdomain (violates [ADR-00025](00025-seo-content-architecture.md)), add
~150 MB of infra plus an upgrade/monitor path, and force a second account —
users logged into FluxVale would register again on the board. The integration
work would exceed the custom build, which is CRUD + votes — the exact shape
this stack was chosen for ([ADR-00002](00002-single-ash-liveview-app.md)).

**Decision**:

1. **In-app board** at `fluxvale.com/feedback`: `Feedback.Post` (title, slug,
   description, status `open/planned/started/completed/duplicate/declined`,
   optional catalog-app tag), `Feedback.Vote` (unique per org per post),
   `Feedback.Comment`. Vote counts as cached aggregates.
2. **Policies**: read → `actor_absent` allowed (public); create
   post/vote/comment → **`paying_customer?`** — wallet has ≥1 completed
   purchase transaction — or admin. The gate doubles as spam protection by
   construction (the #1 pathology of public boards, solved structurally).
3. **Sequencing**: ships with the beta/billing milestone (the gate is only
   meaningful once payments exist). Until then the same check runs in
   **allowlisted-OR-paying mode** ([ADR-00023](00023-day-one-gates.md)
   AccessRule pattern), so the board opens with the invite cohort and
   tightens itself the day the first purchase lands.
4. **Pages**: `/feedback` board and `/feedback/:slug` post pages as SSR
   controllers (crawlable, sitemap'd — per ADR-00025); voting/commenting
   interactions as LiveView on top; small admin moderation LiveView (status
   changes, duplicate merges). App-tagged posts cross-link to
   `/apps/<slug>`.
5. **API surface**: feedback resources are JSON:API/CLI/MCP-accessible per
   [ADR-00019](00019-machine-first-api-cli-mcp.md) — agents can file and
   search feedback on the customer's behalf.

## Amendment 1 (2026-09-01)

*(Consolidated in [ADR-0027](00027-admin-surface-ashadmin.md).)*

**Moderation day one rides AshAdmin** (ADR-0023 Am. 2) — status edits and
custom actions are exposed through generated resource forms. The purpose-built
moderation LiveView (duplicate-merge workflow, bulk views) is deferred until
the workflow outgrows generated CRUD.
