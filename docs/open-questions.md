# Open Questions

Deliberately undecided. If a work session needs one answered, surface
it — don't invent. Resolved items shrink to a pointer; the ADR carries
the decision.

## Next up

1. **Domain-model cut and build order** — resolved by
   [ADR-0030](adr/00030-ops-domain.md) (grouping) and
   [ADR-0031](adr/0031-build-order.md) (milestone ladder; custom
   domains + SFTP deferred post-beta). M1 = walking skeleton.

## Product

2. **v2 launch gate** — v1's "FluxVale Sorted" gate (SFTP E2E, 5-app
   catalog, billing essentials, verified backups/restore, private
   beta) needs a v2 restatement. Which items make the v2 gate?
3. **Catalog lineup** — Forgejo #1 ([ADR-0031](adr/0031-build-order.md)
   M3 seed: the org's own git forge; SSH disabled initially,
   HTTPS-only git — the v1 port-22 lesson; SQLite-on-PVC) — the first
   seeded entry (#70's YAML ships empty until #71). Kavita **deferred
   with SFTP** (OQ #6): a library app is useless without file ingest
   (dropped from #70's seed pre-merge, 2026-09-21). Remaining dogfood
   apps TBD (v1 queued: ActualBudget, PocketID, SilverBullet, +1).
   Also: per-app mount-path/command overrides in the deployer (v1
   #360) — needed for non-`/data` apps.
4. **Payments provider** — resolved by
   [ADR-0029](adr/00029-payments-adapter-selfmor.md): self-MoR with
   HitPay behind a PaymentProvider adapter (PH entity; Stripe
   unavailable there; Xendit swapped out pre-implementation, Am. 2).
   Open launch-gate item: PH tax treatment of exported digital
   services + prepaid-credits classification.
5. **Welcome credits anti-abuse** — mostly resolved by passwordless
   email-code auth (login proves inbox ownership by construction,
   [ADR-0003](adr/00003-ashauthentication-drop-authentik.md));
   remaining edge: disposable-email-domain handling.
6. **SFTP / file access** — deferred post-beta, but it was a v1 gate
   item and churn source (shared gateway vs sidecar, v1 #353/#374).
   Decide the v2 stance when redefining the gate.

## Platform

7. **Server provisioning** — reuse v1's `nuremberg-01` or fresh
   Netcup order? Maintainer stance (2026-09-18): wipe-and-reuse at
   cutover stays preferred, no rush — v1 remains occasionally useful
   until then. Final call at M4 planning;
   fresh order is the fallback if v2 readiness outlasts v1's useful
   window. (v1's operational quirks are documented in the
   [v1 repo](https://github.com/fluxvale/fluxvale_old)'s AGENTS.md;
   per [ADR-0018](adr/00018-repo-visibility.md), operational
   specifics are not restated in this public repo.)
8. **Repo bootstrap** — settled: `fluxvale/fluxvale` public FSL-1.1,
   fleet repo private `fluxvale/infrastructure`, image
   `ghcr.io/fluxvale/fluxvale`
   ([ADR-0018](adr/00018-repo-visibility.md)). Still open: CI
   skeleton.
9. **API surface details** — headline settled by
   [ADR-0019](adr/00019-machine-first-api-cli-mcp.md) (JSON:API + CLI
   + MCP day one). Versioning **resolved** (#24, 2026-09-08): URL
   prefix `/api/v1/…` from the first public route — no unversioned
   aliases, no media-type negotiation (fights the JSON:API media
   type, invisible to generated clients, `Vary` busts caches); a v2
   mounts alongside v1. CLI login UX decided (2026-09-07,
   pre-implementation): gh-style **thin device flow, RFC
   8628-shaped** — the wire is RFC 8628's from day one
   (`device_code`/`user_code`/`verification_uri`/`expires_in`/
   `interval`; polling errors `authorization_pending`/`slow_down`/
   `access_denied`/`expired_token`), so a later full implementation
   is server-internal — **the CLI never changes**. `DeviceCode`
   carries `client_id`+`scope` (single seeded first-party client,
   full access); minted tokens carry client/scope provenance
   (`extra_data`/claims). The upgrade delta is the client registry +
   scope negotiation, not plumbing; scope *enforcement* is the
   deliberately deferred half. Promotes to an ADR + issue with the
   CLI milestone. Still open: CLI language + distribution (generated
   from the OpenAPI spec? single static binary?); MCP tool-set
   design (which actions, confirmation UX for destroy/billing ops).
10. **Feature flag resource design** — resolved by
    [ADR-0023](adr/00023-day-one-gates.md) (FeatureFlag resource +
    evaluator, fail-closed, atom-safe keys, sticky rollouts,
    AshAdmin-administered); also settles staging's sign-in gate
    (AccessRule) and pre-builds the private-beta invite flow.
11. **Local dev cluster** — resolved by
    [ADR-0020](adr/00020-local-dev-parity.md) (k3d + Tilt + `local/`
    overlay). Remaining at scaffolding: dev-image Dockerfile, the
    Tiltfile.
12. **Backups detail** — CNPG barman → R2 configuration, retention,
    restore-drill cadence (quarterly?). Launch-gate material.
13. **Bruno/Playwright suites** — resolved by
    [ADR-0024](adr/00024-e2e-review-environments.md): port v1's
    bones, re-point, add per-PR (review env) / staging-full /
    prod-readonly / local runtimes + TestInbox adapters. Suite at
    `apps/e2e`.

## Deferred (with triggers — [ADR-0016](adr/00016-deferred-triggers.md))

Longhorn at node #2 · control-plane HA at 3 server nodes · dedicated
staging box · Flagger canary at traffic · self-hosted LGTM at
free-tier limits · managed k8s at concrete need · PocketID managed SSO
post-beta · first-party products post-gate.
