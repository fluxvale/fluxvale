# ADR-00019: Machine-first API surface — JSON:API, CLI, and MCP server from day one

**Status**: Accepted
**Date**: 2026-08-27

**Context**: users increasingly operate services through their AI agents, not
through web UIs. A PaaS whose primary surfaces include a machine API, a CLI,
and an MCP server meets users where they now are — and is a differentiator
the category (DIY panels, existing managed hosts) does not ship. This
reverses the earlier lean ([ADR-00002](00002-single-ash-liveview-app.md) consequence: "JSON:API is a future
decision") — the JSON:API is now a **first-class, day-one surface**, because
it is the substrate for both machine clients.

**Decision**:

1. **JSON:API (`ash_json_api`) is designed in from the first Ash resource** —
   routes, public attributes, and includes are deliberate API design, not an
   afterthought of the LiveView UI. The API is a compatibility contract:
   breaking changes to it are versioned decisions, unlike LiveView internals
   which are free to move.
2. **CLI** — a first-class client over the JSON:API, authenticated with
   PATs (the 1-yr PAT design from v1). Instance lifecycle (create/deploy/
   stop/start/destroy/status), billing balance, catalog listing. Generated
   where possible: v1's offline OpenAPI dump (spec rendered from compiled
   Ash resources — no running server needed) feeds client generation and a
   CI staleness check.
3. **MCP server** — FluxVale speaks MCP so a user's agent can operate their
   instances directly. Preferred shape: **hosted streamable-HTTP MCP endpoint
   served by the Phoenix app itself** (one deployment, versioned with the
   API, PAT-authenticated). A thin local package (stdio wrapper around the
   same API) can follow for users who prefer it.
4. **Machine auth = PATs** with scoped, auditable access; agent-driven
   actions get rate limits like any other API client.

**Consequences**:

- Every feature ships with: Ash resource + LiveView surface + API route.
  "Is there an API route for this?" is part of definition-of-done.
- The API surface is versioned deliberately from the start (URL-prefix or
  media-type versioning decided at scaffolding).
- MCP security is part of the API security model: agents act with the user's
  PAT; dangerous actions (destroy, billing) need confirmation UX in the MCP
  tool design.
- Scope discipline: CLI and MCP land **after** the API + LiveView for a given
  capability exist — they are clients, not drivers, of the domain model.

## Amendment 1 (2026-11-03): PATs are opaque, hashed, and scoped at the boundary

The #23 JWT PAT mint is replaced (#360): PATs are single-part opaque
values (`fvpat_…`) shown once at mint and stored only as SHA-256
hashes — a DB leak reveals nothing reusable, and no long-lived signed
machine credential exists to outlive a key compromise. Scopes are
read/write per domain (`instances, backups, gateways, wallet,
catalog`; `wallet`/`catalog` read-only for now), enforced at the
`/api/v1` boundary inside the 401/403 contract — resource policies
stay scope-unaware. Session auth on `/api/v1` is read-only (CSRF:
writes are token-only). Per-token rate limits and audit land as
later slices of #360.
