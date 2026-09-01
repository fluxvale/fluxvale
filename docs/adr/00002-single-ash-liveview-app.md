# ADR-00002: Single Phoenix + Ash + LiveView app; no SPA

**Status**: Accepted
**Date**: 2026-08-27

One OTP release: LiveView UI + app logic in Ash.

**Context**: v1's `apps/web` (~28k LOC React/TS) existed to mirror the backend
— OpenAPI→`types.ts` generation with a CI staleness check, JSON:API adapters,
polling loops for instance deploy status. v1 epic #386 itself concluded the SPA
was the wrong bet for "CRUD + one live surface" (the instance deploy stepper
wanting to be a live stream was the tell). `AshPhoenix.Form` binds resources directly and
deletes the translation layer.

**Consequences**: no web image, no web CI, no types-generation pipeline, one
deployable. The UI no longer *requires* a JSON:API — but machine clients do:
per [ADR-00019](00019-machine-first-api-cli-mcp.md) the JSON:API is a first-class day-one surface for the CLI and
MCP server. What stays dead from v1 is the SPA-side translation layer
(OpenAPI→`types.ts`→adapters) — the spec now generates *client* tooling, not a
frontend.
