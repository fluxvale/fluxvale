# ADR-0031: Build order — the milestone ladder

**Status**: Accepted
**Date**: 2026-09-01

**Context**: OQ #1's final piece. The resource inventory is assembled across
the ADRs; grouping is settled ([ADR-0030](00030-ops-domain.md)). This ADR
fixes the sequence and confirms the deferrals.

**Principles**: every milestone ends in a demo; risk goes local first
(k3d before the box); the box arrives when something is worth deploying
(not first, not last); payments trail — welcome credits carry the beta.
Port-don't-rewrite from the salvage map throughout.

**The ladder**:

- **M1 — Walking skeleton**: monorepo scaffold (`apps/platform`, `apps/e2e`),
  Phoenix+Ash boot, `/health` with build SHA, k3d + Tilt stack (validates
  [ADR-00020](00020-local-dev-parity.md) → Accepted), `mix ci` + CI
  skeleton, AshAdmin mounted. *Exit: healthy app via Tilt; green CI.*
- **M2 — Identity + Ops**: passwordless email codes (Swoosh local + gated
  TestInbox), sessions, PATs, the full `Ops` domain (AccessRule,
  FeatureFlag). *Exit: local login via TestInbox; PAT hits `/api/me`.*
- **M3 — The heart**: Catalog + **Forgejo** seed (first app — the org's
  own git forge; SSH disabled initially, HTTPS-only git — the v1 port-22
  lesson; SQLite-on-PVC; env config via FORGEJO__section__KEY), k8s client
  port, Cluster,
  Instance state machine + four Oban triggers into `fluxvale-app-*`
  namespaces in k3d, the LiveView catalog→deploy→status flow. *Exit:
  install Forgejo locally → running → instance URL opens → stop/destroy.*
- **M4 — The box goes live**: Talos install, Flux bootstrap, the fleet repo
  is born (overlays, BWS operator, CNPG + WAL-G, Traefik, cert-manager, the
  full observability stack per [ADR-0012](00012-observability-grafana-cloud.md)),
  first simultaneous staging+prod deploy, Bruno smoke (PAT).
  *Exit: both domains serving; alerts wired.*
- **M5 — Billing**: Organization/Membership, Wallet + ledger, welcome
  credits, flat-rate accrual ([ADR-00028](00028-flat-rate-pricing.md)),
  balance UI, empty-wallet deploy gate. *Exit: accrual lands in the ledger.*
- **M6 — Payments**: `PaymentProvider` behaviour + Xendit
  ([ADR-0029](00029-payments-adapter-selfmor.md)), buy-credits.
  *Exit: test-mode checkout credits a wallet.*
- **M7 — Launch-prep**: blog + SEO plumbing ([ADR-00025](00025-seo-content-architecture.md)),
  public catalog pages, feedback board ([ADR-0026](00026-feedback-board.md)),
  review-env workflow in the fleet repo + per-PR Playwright
  ([ADR-00024](00024-e2e-review-environments.md)), the restore drill, then
  the launch-gate restatement (OQ #2) → private beta.

**E2E grows progressively**: local suite from M3, staging suite at M4,
per-PR at M7 — never a standalone milestone. The Talos install is
independent of the ladder and may be pulled forward at will.

**Deferrals confirmed**: custom domains and SFTP/file access are post-beta.

**Resolves**: OQ #1 in full.
