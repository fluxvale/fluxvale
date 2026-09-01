# ADR-00017: Docs home — one ADR log here, covering the product and org-wide infrastructure

**Status**: Accepted
**Date**: 2026-08-27

**Context**: with two repos planned for the platform (app + fleet) and more
SaaS products to come under the FluxVale org, decisions needed a home.
Considered and rejected:

- **A separate docs/ADR repo** — docs-only repos are where documents go to
  die; nobody (human or agent) browses them from either working repo. It also
  breaks the PR-coupled workflow (ADR amendment reviewed in the same PR as
  the code it governs) and fragments the numbered sequence.
- **Splitting the log per-repo** — most platform decisions deliberately span
  both repos ([ADR-00008](00008-app-runs-in-cluster.md), 00011, 00013, 00014); a split log breaks
  cross-references and the amendment/supersession chain.

**Decision**:

1. **This repo (`fluxvale/fluxvale`) is the project home** and holds the
   single ADR log, whose scope is:
   - **FluxVale the product** (the PaaS: catalog, instances, billing), and
   - **the shared infrastructure for every SaaS product under the FluxVale
     org/corporation** — fleet repo, cluster, edge (Cloudflare/Traefik),
     CNPG clusters, deploy pipeline, observability.
2. **The fleet repo (`fluxvale/infrastructure`) holds the cluster’s state and its operational docs** — Talos machine-config patches, all manifests, runbooks (`DEPLOYMENT.md`, bootstrap, rotations) (no decision records —
   those live here); its README links
   back: "Project-wide decisions live in `fluxvale/fluxvale` → `docs/adr/`;
   read them before proposing changes."
3. **Other SaaS products keep their own app-specific ADRs in their own
   repos**, scoped to their own problems. Decisions that affect the platform
   or shared infrastructure on their behalf (e.g., the shared CNPG cluster)
   are made and recorded **here**.

**Scope boundary (when in doubt)**: affects the platform, cluster, edge,
shared databases, deploy pipeline, or the FluxVale product → this log.
Affects one app's internals → that app's repo.

**Rule**: cross-link, never mirror — duplicated docs rot at different speeds.

**Revisit trigger**: if multiple product repos end up sharing the platform, a
dedicated architecture repo may justify itself (see [ADR-00016](00016-deferred-triggers.md)).
