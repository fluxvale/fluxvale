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
   via `Ash.UUIDv7` — `uuid_primary_key(:id, type: :uuid_v7,
   default: &Ash.UUIDv7.generate/0)`. The explicit `default` is required:
   the type alone keeps the built-in v4 generator (the trap this ADR's
   first implementation hit). Postgres storage stays `uuid`; no
   column-type implications.
2. **Ordering is approximate, never a contract.** v7 id order ≈ creation
   order (cross-replica clock skew). Pagination cursors may use id order
   as a convenience; anything needing strict order (ledger sequence) keeps
   explicit ordering semantics of its own.
3. **No DB-side id default**: ids are generated app-side only — the column
   default is nil (via `migration_defaults`). ash_postgres would otherwise
   emit `uuid_generate_v7()` — a function no stock Postgres provides (not
   core, not `uuid-ossp`; PG18's native one is `uuidv7()`), so a DB-side
   default is unbuildable without third-party extensions regardless of
   floor — and a v4 `gen_random_uuid()` backstop would silently mint
   mismatched-version ids on any non-Ash write. Instead, an insert that
   omits `id` fails loudly (`NOT NULL id`) — a guardrail, not full
   enforcement: Postgres `uuid` is version-agnostic, so a non-Ash writer
   can still supply an explicit v4; DB-side v7 enforcement (a version-bit
   CHECK constraint) is judged not worth the write cost on a path this
   ADR declares shouldn't exist. Revisit only if a non-Ash writer ever
   appears (then wire a real v7 source — PG18's `uuidv7()` or a SQL shim).
4. Creation-time metadata in ids is accepted: 74 random bits remain
   unguessable, and ids are never a security boundary (policies are —
   [ADR-0027](00027-admin-surface-ashadmin.md) posture). String PKs
   (Token `jti`) are unaffected.

**Rejected**: **v4** — the framework default; index-locality loss on
append-mostly tables and composite `(created_at, id)` cursors everywhere.
**ULID/shortids** — not UUID-shaped; a second id format would leak into
the API contract. **v6/v8** — field-ordered variants without first-class
Ecto/Ash support in the pinned versions.
