# ADR-00024: E2E architecture + review environments (per-PR Playwright on the single box)

**Status**: Accepted
**Date**: 2026-09-01

**Context**: per-PR Playwright runs were desired from the start. Verification
on *ephemeral* environments is fully compatible with simultaneous deploy
([ADR-0011](00011-simultaneous-deploy-post-deploy-smoke.md)) — no version
skew exists because nothing deployed persists. Review apps also serve human
review: a clickable `pr-<n>.review.fluxvale.app` per PR.

**Options weighed**: (A) review environments on the single production box —
**chosen**; capacity is an accepted cost, and the second box arrives when
paying customers make it a happy problem ([ADR-00016](00016-deferred-triggers.md)
node-#2 trigger). (B) k3d inside CI runners — zero-cost and credential-free
but ephemeral (no clickable review apps). (C) a dedicated review cluster —
rejected: no second server pre-revenue. Also rejected: giving app-repo CI a
cluster ServiceAccount — **RBAC cannot pattern-restrict namespace names**, so
"may create `fluxvale-pr-*` namespaces" is not expressible without hoping.

**Decision**:

1. **The platform provisions its own review environments** — a
   `ReviewEnvironment` Ash resource + API action. CI authenticates with a
   scoped FluxVale service PAT (**an app credential — the
   [ADR-0007](00007-fluxcd-fleet-repo.md) no-cluster-credentials boundary
   stays intact**), and the platform — which already creates namespaces for
   a living — renders the blueprint per PR:
   `fluxvale-pr-<n>` namespace + the PR image's deployment + a disposable
   Postgres pod (migrations + seeds) + Mailpit + a Traefik route +
   a ResourceQuota cap. Naming rules, quotas, and prefixes are enforced in
   Elixir, where pattern rules are trivial.
2. **Collision safety**: review envs seed a per-PR Cluster record with
   `INSTANCE_NAMESPACE_PREFIX=fluxvale-pr-<n>-app-` and a subdomain suffix
   (`mykavita-pr-<n>.review.fluxvale.app` — single-level wildcard suffices).
3. **Lifecycle**: created/updated on PR open/push; deleted on PR close
   (webhook or janitor sweep); hard cap of 2–3 concurrent review envs to
   bound RAM. Review envs are disposable by the same rule as staging
   ([ADR-0010](00010-staging-namespace-flag-gated.md)).
4. **Suite**: lives at `apps/e2e/` (monorepo, v1 suite ported; screenshots/
   traces → CI artifacts). Four runtimes: **per-PR** (full suite against the
   review env, destructive allowed), **post-deploy staging** (full suite),
   **post-deploy prod** (read-only subset — no side effects, no credits
   spent), **local** (against the Tilt/k3d stack, ADR-0020).
5. **TestInbox adapter**: one helper, three backends — Mailpit (local,
   staging, review envs) and Postmark Messages API (prod,
   [ADR-00003](00003-ashauthentication-drop-authentik.md) Am. 1). Deterministic
   passwordless login everywhere, zero test backdoors.
6. **LiveView discipline**: `data-testid` attributes; assert user-visible
   states ("badge says Running"), never Phoenix internals; generous polling
   timeouts on the instance-lifecycle test (it crosses the real cluster).

**Resolves**: open question #13 (port v1 suites, re-point, add the
per-PR/staging/prod split + adapters).
