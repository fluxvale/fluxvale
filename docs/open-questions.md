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
   beta) needs a v2 restatement. Which items make the v2 gate? One
   settled input: cross-border VAT gates — registrations, checkout
   tax evidence, and per-country return data before the first real
   charge ([ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3).
3. **Catalog lineup** — Forgejo #1 ([ADR-0031](adr/0031-build-order.md)
   M3 seed: the org's own git forge; SSH disabled initially,
   HTTPS-only git — the v1 port-22 lesson; SQLite-on-PVC) — seeded
   (#71, v16.0.5). Kavita **deferred
   with SFTP** (OQ #6): a library app is useless without file ingest
   (dropped from #70's seed pre-merge, 2026-09-21). Remaining dogfood
   apps TBD (v1 queued: ActualBudget, PocketID, SilverBullet, +1).
   Also: per-app mount-path/command overrides in the deployer (v1
   #360) — needed for non-`/data` apps.
4. **Payments provider** — resolved by
   [ADR-0029](adr/00029-payments-adapter-selfmor.md): self-MoR with
   HitPay behind a PaymentProvider adapter (PH entity; Stripe
   unavailable there; Xendit swapped out pre-implementation, Am. 2).
   Open launch-gate advisor items (map + registration gates decided,
   [ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3): OSS
   member state, prepaid-credits voucher classification, PH
   zero-rating documentation, DIY vs agent filings.
5. **Welcome credits anti-abuse** — mostly resolved by passwordless
   email-code auth (login proves inbox ownership by construction,
   [ADR-0003](adr/00003-ashauthentication-drop-authentik.md));
   remaining edge: disposable-email-domain handling.
6. **SFTP / file access** — deferred post-beta, but it was a v1 gate
   item and churn source (shared gateway vs sidecar, v1 #353/#374).
   Decide the v2 stance when redefining the gate.
14. **Managed databases as a first-party product** — long-term
    interest (2026-09-25): a Layerbase-shaped offering (flat-rate
    multi-engine DB cloud with branching) sold like an instance.
    Post-gate, on the first-party-products trigger
    ([ADR-0016](adr/00016-deferred-triggers.md)); activation needs an
    [ADR-0009](adr/00009-single-cnpg-cluster.md) amendment — where
    customer DBs live (the shared cluster assumes all-first-party
    cotenants). Stance: steal the product shape, not the engine
    count — per-engine ops load (backups/upgrades/CVEs × engines)
    doesn't shrink with bigger servers; start 1–2 engines, add on
    trigger; no CoW branching (dump-to-scratch covers rehearsals —
    ADR-0009's internal drill pattern). Shapes: (a) **DB as catalog
    app** — Postgres/Valkey as catalog entries (web IDE + connection
    string); stopped=storage-only already prices idle DBs right.
    (b) **Dev-facing DB cloud** — `fluxvale db` on the day-one CLI/MCP
    surface ([ADR-0019](adr/00019-machine-first-api-cli-mcp.md));
    edge: one bill, one agent surface, apps *and* data. Seed a
    provisioning layer only if instances ever get platform-provisioned
    DBs (unsettled — ADR-0005 instances are namespace + Deployment +
    PVC; Forgejo runs SQLite-on-PVC); then with a clean seam.

## Platform

7. **Server provisioning** — resolved (#93, 2026-09-28):
   wipe-and-reuse `nuremberg-01`. The fresh-order fallback didn't
   fire — M3 done, M4 is the cutover, so v1's useful window ended on
   schedule. Topology settled same day: single control plane,
   workloads on it
   ([ADR-0022](adr/00022-talos-linux.md) Am. 1). (v1's operational
   quirks are documented in the
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
15. **E2E coverage of new pages** — Playwright can't know the UI's
    full surface, so "every route has a spec" is invisible without
    help (surfaced after #91, 2026-09-26). Today: manual audit —
    `mix phx.routes` vs. the suite's path references (~7 user routes;
    milestone issues scope e2e growth per
    [ADR-0024](adr/00024-e2e-review-environments.md)). Revisit
    trigger: page-count growth at M5 (billing UI) / M7 (public pages),
    or the first untested page that ships — then a CI route-tripwire
    (diff the router's **browser-scope** routes — LiveView/page GETs,
    not `/health`, `/api/v1`, session POST/DELETE — against the
    suite's path references, fail on untouched routes, exclusions
    list for `/admin` and the TestInbox UI), honoring
    [ADR-0020](adr/00020-local-dev-parity.md)'s
    felt-pain tooling rule.
16. **Platform-SA cross-env bind scope** — surfaced by the fleet-repo
    RBAC port (fluxvale/infrastructure#1 review, 2026-09-27): the #69
    operator pattern grants each env's platform SA cluster-wide
    Namespace/RoleBinding authority plus `bind` on
    `fluxvale-platform-workload` — sound with one env, but staging and
    prod share one cluster (M4), so a compromised staging SA can bind
    the workload role in `fluxvale-production` and reach prod Secrets.
    No cheap RBAC-only fix: Namespace `create` cannot be name-scoped
    (`get`/`patch`/`delete` can use `resourceNames`, `list` a
    `metadata.name` field selector — but the SA must create the
    namespaces it operates on), and instance-namespace RoleBinding
    grants bootstrap badly (the SA must hold a right before it can
    grant itself). Decide before customer
    instances carry real data: accept (credentials are in-cluster SA
    tokens; blast radius is two first-party envs) or constrain via
    admission policy (confine binds/RoleBindings to `fluxvale-app-*`
    namespaces) at the M5 instance-hardening pass.

## Deferred (with triggers — [ADR-0016](adr/00016-deferred-triggers.md))

Longhorn at node #2 · control-plane HA at 3 server nodes · dedicated
staging box · Flagger canary at traffic · self-hosted LGTM at
free-tier limits · managed k8s at concrete need · PocketID managed SSO
post-beta · first-party products post-gate (managed-DB product,
OQ #14).
