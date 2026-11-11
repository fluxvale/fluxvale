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
writes are token-only). Per-token rate limits landed (#360: fixed
window per token, 300/min default, 429 + `Retry-After`); every
PAT-authenticated call and each mint/revoke lands an append-only
audit row (token id, method, path, status — never the token value),
90-day retention.

## Amendment 2 (2026-11-04): the MCP server landed — tool surface is contract

S2 of #359 shipped the hosted MCP endpoint (#361): `POST /mcp` in the
Phoenix app (§3's stance), streamable HTTP, protocol rev 2026-07-28
only — the stateless core, no sessions. Tools call the same Ash
actions with the PAT-resolved actor: policies, paywall, and scopes
enforce exactly as over `/api/v1`; the MCP layer is adapter, not
authority. Scope enforcement is two-layered at the tool surface —
`tools/list` is filtered by the token's grants (a read-only token
never sees a write tool) and every handler re-checks before dispatch,
against the same scope catalog and implication rule the route gate
rides (the route table maps paths, the tool table maps tools —
necessarily distinct tables, kept honest by set-equality tests).
Destructive tools (`restore_backup`, `destroy_instance`) confirm
through the protocol's multi-round-trip input flow — an encrypted,
stateless confirmation that mutates nothing until a "yes". The tool
list is a compatibility contract in §1's sense: additive within the
surface; removal or rename is a versioned decision. First consumer
is our own agent fleet — dogfooding is the acceptance path (#361's
note). Audit granularity note: MCP tool calls audit as `POST /mcp`
rows (token, status) — the tool NAME is not yet an audit field, so
per-tool attribution over MCP is a named follow-up.

## Amendment 3 (2026-11-04): the CLI is Rust — OQ #9's CLI half closes

The CLI's language + distribution are decided: **Rust**, distributed
as per-OS static binaries from a cross-compile matrix (linux
amd64/arm64, macOS, Windows) published to GitHub Releases. The
decision is a deliberate trade of monorepo fluency for distribution
quality: one static binary per target, a mature cross-compile story,
and a first-class CI matrix — the strongest distribution posture for
a tool end users run on arbitrary machines.

The Elixir recommendation (same stack, one author, Burrito binaries —
recorded in #362's research) is the rejected alternative: it kept
repo fluency but bet distribution on a packaging toolchain with less
proven reach than Rust's. Revisit trigger unchanged: external
contributors or a plugin ecosystem.

The client is a thin presentation layer over `/api/v1` — all logic
stays server-side; serde types are generated from the committed
OpenAPI artifact (§2's dump), so API changes flag the CLI at build
time. Login is the RFC 8628 device flow (OQ #9's pre-decided wire);
tokens live in the OS keychain where available, 0600 file fallback.
The CI lane mirrors the BEAM disciplines in Rust — fmt + clippy
`-D warnings` + test + `cargo deny` (license allowlist; GPL family
denied) + llvm-cov on codecov + the 4-target matrix on every PR,
path-isolated from the BEAM lanes.

## Amendment 4 (2026-11-06): the Terraform/OpenTofu provider — the fourth skin

The provider lands in the monorepo at `apps/tfprovider`: Go +
terraform-plugin-framework, a thin client over `/api/v1` with PAT auth
(provider `token` attribute or the `FLUXVALE_PAT` env var). Same
stance as the CLI and MCP: policy, paywall, and scopes enforce
server-side — the provider re-implements nothing. v0 is a scaffold
(provider config + client + CI lane); resources and data sources land
in follow-up slices (#482).

Distribution mirrors Am. 3's posture: manual-first via GitHub
Releases carrying registry-shaped archives
(`terraform-provider-fluxvale_X.Y.Z_OS_ARCH.zip` + `SHA256SUMS`)
under namespaced `tf-v*` tags. registry.terraform.io (a
dedicated `terraform-provider-fluxvale` repo + GPG signing) is
deferred until a second user exists.

Compatibility contract: config attribute names
(`api_url`/`token`/`organization`), `FLUXVALE_PAT`, and
resource/data-source type names are stable from day one
(`apps/tfprovider/docs/compatibility.md`); the rest of the schema may
move through 0.x — dogfooding-first, the owner is user #1. 1.0 freeze
at the first external user writing `.tf` against the provider.

Rejected: SDKv2, and generating the client from the committed OpenAPI
dump (the CLI's approach — the provider maps hand-written schema
semantics, not raw API shapes); revisit if schema drift pain says
otherwise.

## Amendment 5 (2026-11-09): the MCP server is Rust — standalone, elicitation-gated, subdomain-hosted

The standalone Rust server (`apps/mcp`, rmcp 3.9.0, streamable HTTP,
stateless) replaces Am. 2's Phoenix-hosted endpoint: the Phantom
`POST /mcp` on the platform app is retired at cutover with zero
external clients (pre-beta; the tokens-panel quickstart #640,
[`docs/mcp.md`](../mcp.md), and the public automation page all teach
only the remote server post-fix). The Rust surface is the INITIAL
published contract — the rename set (`list_apps`→`apps_list` et al.)
and the unported verbs (gateway lifecycle get/create/resume/attach/
detach, `set_instance_always_on`, `set_instance_exposure` — 22
Elixir tools → 17 Rust) are pre-publication surface, not a versioned
break.

The Rust side of the repo becomes three workspaces: `apps/cli`,
`crates/fluxvale-api` (the shared `/api/v1` client), `apps/mcp` — two
lockfiles → three by the same rationale. Auth is PAT passthrough (the
server holds no credentials); the platform boundary stays the
enforcement, so every upstream call lands the same per-route audit +
rate-limit, with per-path attribution where Phantom's opaque
`POST /mcp` rows had none. `tools/list` is filtered by the calling
token's scopes read from `/me`'s `meta.scopes` (#585 — a runtime
render, deliberately NOT in the OpenAPI artifact; generated clients
learn it from [`docs/mcp.md`](../mcp.md)).

Destructive gating is SEP-2322 MRTR: the first call answers
`input_required` carrying a yes/no confirm question plus an
HMAC-sealed `requestState` keyed to the calling PAT — TTL-bounded
(ten minutes), not single-use; a seal from another token never opens.
A client that cannot confirm gets an honest error naming the panel —
never a silent no-op, and the verb never runs.

The host is a dedicated subdomain — `mcp.fluxvale.com` /
`mcp.staging.fluxvale.com` (DNS records pending rollout), the
protocol nesting at `/mcp` on that host. Subdomain over path-on-the-app-host: ecosystem convention (an
MCP server is advertised as one URL), traffic isolation, independent
edge rules, and a clean OAuth resource origin. Certs are DNS-01; the
A records are client-reachability only. Deployment posture: own image
(`ghcr.io/fluxvale/fluxvale-mcp`) under Flux image automation, on a
hardened pod — no SA token, non-root, read-only rootfs.

Rejected: the stdio subcommand (deferred — revisit trigger: a real
stdio-only client asks), a second Phoenix endpoint (a cross-workspace
dep-graph cycle), and Phantom retention (two surfaces drift — the
exact fate this cutover exists to prevent).

Straggler note: [ADR-0047](00047-platform-admin-authority.md)'s
doctrine loses no teeth at cutover —
`FluxVale.Checks.CallOutsideMachineApi` and both its rungs survive on
`/api/v1` (the plug chain remains the writer); the `/mcp` handler
writer retired with the endpoint, so ADR-0047's `/mcp` bullet now
describes history.
