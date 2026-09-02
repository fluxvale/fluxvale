# ADR-0032: IDs are UUIDv7

**Status**: Accepted
**Date**: 2026-09-02

**Context**: the first Ash resource (#20) fixes the id pattern every later
resource copies — the cheap moment to choose. Ash's `uuid_primary_key`
defaults to v4 (random). The platform's growth tables are append-mostly:
the M5 Wallet ledger (idempotency-keyed postings ported from v1), Instance
state churn (M3), feedback board entries. The machine-first API
([ADR-0019](00019-machine-first-api-cli-mcp.md)) wants stable keyset
cursors for listing endpoints. Switching after launch means backfilling
live rows into a permanently mixed-version column — the retrofit class
the port-22 lesson codifies.

**Decision**:

1. Every uuid primary key is **UUIDv7** (RFC 9562), generated **app-side**
   via `Ash.UUIDv7` — `uuid_primary_key(:id, type: :uuid_v7)`. Postgres
   storage stays `uuid`; no column-type implications.
2. **Ordering is approximate, never a contract.** v7 id order ≈ creation
   order (cross-replica clock skew). Pagination cursors may use id order
   as a convenience; anything needing strict order (ledger sequence) keeps
   explicit ordering semantics of its own.
3. **DB backstop**: ash_postgres emits `gen_random_uuid()` (v4) as the
   column default. Accepted — every write goes through Ash, so it is a
   never-hit path; revisit only if a non-Ash writer appears, or when the
   CNPG version choice (M4) makes PG18's native `uuidv7()` free.
4. Creation-time metadata in ids is accepted: 74 random bits remain
   unguessable, and ids are never a security boundary (policies are —
   [ADR-0027](00027-admin-surface-ashadmin.md) posture). String PKs
   (Token `jti`) are unaffected.

**Rejected**: **v4** — the framework default; index-locality loss on
append-mostly tables and composite `(created_at, id)` cursors everywhere.
**ULID/shortids** — not UUID-shaped; a second id format would leak into
the API contract. **v6/v8** — field-ordered variants without first-class
Ecto/Ash support in the pinned versions.
