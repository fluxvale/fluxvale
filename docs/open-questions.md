# Open Questions

Deliberately undecided. If a work session needs one of these answered, surface
it — don't invent.

## Next up

1. **Domain-model cut and build order** — the last pre-scaffold decision.
   Working sketch (not yet agreed): keep Instance lifecycle + catalog + billing
   wallet/ledger/metering from v1; defer custom domains and SFTP/file access
   to post-beta. Milestone-one definition pending.

## Product

2. **v2 launch gate** — v1's "FluxVale Sorted" gate (SFTP E2E, 5-app catalog,
   billing essentials, verified backups/restore, private beta) needs a v2
   restatement. Which items make the v2 gate?
3. **Catalog lineup** — Kavita was v1's only seeded app. The other four
   dogfood apps (v1 queued: ActualBudget, PocketID, SilverBullet, +1). Also:
   per-app mount-path / command overrides in the deployer (v1 #360) — needed
   for non-`/data` apps.
4. **Payments provider** — resolved by
   [ADR-0029](adr/00029-payments-adapter-selfmor.md): MoR products are out
   (they refuse hosting categories); self-MoR with Stripe behind a
   PaymentProvider adapter. Launch-gate item: EU VAT classification of
   prepaid credits (Stripe Tax).
5. **Welcome credits anti-abuse** — largely resolved by passwordless
   email-code auth (login proves inbox ownership by construction —
   [ADR-00003](adr/00003-ashauthentication-drop-authentik.md)); remaining edge: disposable-email-domain handling.
6. **SFTP / file access** — deferred post-beta per the working sketch, but it
   was a v1 *gate* item and a churn source (shared gateway vs sidecar, v1
   #353/#374). Decide the v2 stance explicitly when redefining the gate.

## Platform

7. **Server provisioning** — reuse v1's `nuremberg-01` or fresh Netcup
   order + fresh OS? (v1's operational quirks — SSH port move, SFTPGo on
   :22 — are documented in the
   [v1 repo](https://github.com/fluxvale/fluxvale_old)'s AGENTS.md; per
   [ADR-00018](adr/00018-repo-visibility.md), operational specifics are not restated in this public repo.)
8. **Repo bootstrap** — settled: app repo is `fluxvale/fluxvale`, open
   source under FSL-1.1 ([ADR-00018](adr/00018-repo-visibility.md); LICENSE.md ported); fleet repo is
   private `fluxvale/infrastructure`; app image is
   `ghcr.io/fluxvale/fluxvale` (matches repo/product name). Still open: CI
   skeleton.
9. **API surface details** — [ADR-00019](adr/00019-machine-first-api-cli-mcp.md) settled the headline (JSON:API + CLI
   + MCP from day one). Still open: API versioning scheme (URL prefix vs
   media type); CLI language + distribution (generated from the OpenAPI spec?
   single static binary?); MCP tool set design (which actions, confirmation
   UX for destroy/billing ops).
10. **Feature flag resource design** — resolved by
    [ADR-0023](adr/00023-day-one-gates.md) (FeatureFlag resource + evaluator,
    fail-closed, atom-safe keys, sticky rollouts, AshAdmin-administered) —
    which also settles staging's `fluxvale.com`-only sign-in (AccessRule
    resource) and pre-builds the private-beta invite flow.
11. **Local dev cluster** — resolved by [ADR-00020](adr/00020-local-dev-parity.md) (k3d + Tilt + CNPG
    in-cluster + a `local/` overlay of the fleet-repo base manifests;
    Proposed until validated on-machine). Remaining details at scaffolding:
    the dev-image Dockerfile (mix-based) and the Tiltfile itself.
12. **Backups detail** — CNPG barman → R2 configuration, retention policy,
    restore-drill cadence (quarterly?). Launch-gate material.
13. **Bruno/Playwright suites** — resolved by
    [ADR-00024](adr/00024-e2e-review-environments.md): port v1's bones,
    re-point, add the per-PR (review env) / staging-full / prod-readonly /
    local runtimes + the TestInbox adapters. Suite lives at `apps/e2e`.

## Deferred (with triggers — see [ADR-00016](adr/00016-deferred-triggers.md))

Longhorn at node #2 · control-plane HA at 3 server nodes · dedicated staging
box · Flagger canary at traffic · self-hosted LGTM at free-tier limits ·
managed k8s at concrete need · PocketID managed SSO post-beta · first-party products post-gate.
