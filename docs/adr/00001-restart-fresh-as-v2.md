# ADR-00001: Restart fresh as v2; carry patterns, not process

**Status**: Accepted
**Date**: 2026-08-27

v1 (Feb–Aug 2026, 467 commits, ~382 PRs) validated the domain model but
accumulated: a React SPA later judged unnecessary, an Authentik-centered
self-hosted-OSS-suite strategy that cost RAM and context, and process/agent
machinery (23 skills, 31 KB AGENTS.md) that grew faster than shipped product.
v2 starts clean; v1 remains a read-only reference for salvage (see
[../v1-salvage.md](../v1-salvage.md)).

**Consequences**: everything in `docs/adr/` and the domain model is decided
consciously rather than inherited; v1 code is ported selectively (salvage
map), never wholesale; process/tooling must justify itself against product
velocity from day one.
