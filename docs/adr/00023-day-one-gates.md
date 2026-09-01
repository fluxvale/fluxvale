# ADR-00023: Day-one gates — access rules + feature flags

**Status**: Accepted (amended — see Amendments 1–3)
**Date**: 2026-09-01

**Context**: two gating needs from day one. (1) **Staging access**: staging
sign-in restricted to `fluxvale.com` addresses — pre-launch, staging is for
the team. (2) **Feature flags immediately**: staging and prod run the same
image simultaneously ([ADR-00010](00010-staging-namespace-flag-gated.md),
[ADR-00011](00011-simultaneous-deploy-post-deploy-smoke.md)), so flags are
the *only* sanctioned divergence — the mechanism must exist before the first
divergent feature does. v1's launch gate also needed an invite flow for
private beta (v1 #385); that is the same mechanism as (1), built once.

**Decision**:

## 1. Access rules — `AccessRule` Ash resource

- Rows of either `domain: "fluxvale.com"` or `email: "someone@example.com"`.
- Checked in the sign-in action **before any code is sent**. Passwordless
  JIT provisioning means blocking the code-send blocks account creation —
  and therefore PATs: the API/CLI/MCP surface
  ([ADR-00019](00019-machine-first-api-cli-mcp.md)) inherits the gate.
- Seeds: staging gets `domain: fluxvale.com` plus `email:
  test@fluxvale.com` (the smoke account); staging SMTP points at a
  catch-all (Mailpit-style) so Playwright reads codes deterministically.
  Prod starts unrestricted — or invite-only via email rows when the private
  beta wants it. Same mechanism, flipped by seeding.
- Admin LiveView; Ash policy restricts mutation to admins.

## Amendment 1 (2026-09-01)

**AccessRules are enforced at every authentication boundary, not only
sign-in.** A rule removed (or an allowlist tightened) must sever machine
access immediately: the check runs at **PAT authentication** (API/CLI/MCP —
one-year tokens must not outlive their owner’s access) and at **session
validation**, with a short-TTL cache to keep it cheap. Otherwise a revoked
user retains API access until token expiry.

## 2. Feature flags — `FeatureFlag` resource + evaluator

- Fields: unique string `key`, `enabled` (default `false`), nullable
  `rollout_percentage` (nil = everyone when enabled), description,
  timestamps. Evaluator: `FeatureFlags.enabled?(key, actor)`.
- **Missing flag = disabled** (fail-closed: flags gate *new* behavior; no
  row anywhere = the new thing is off everywhere; prod-safe before seeds).
- **Atom safety**: flags are declared atoms in code (`@known_flags`);
  DB string keys convert only through the declared list — never
  `String.to_atom/1` on DB input (v1 catalog-seeds lesson).
- **Sticky rollouts**: `:erlang.phash2({key, user_id})` rem 100 < pct —
  deterministic per user, no flip-flopping between variants.
- **Uncached to start** (correct, instantly consistent, ~1 ms at beta
  scale); short-TTL ETS cache only if metrics demand it.
- **Per-env values free by construction** — staging and prod have separate
  databases (ADR-00010).
- Admin surface: a **regular LiveView + `AshPhoenix.Form`** (not Phoenix
  LiveDashboard — that's runtime introspection, and a custom Page would
  bypass the Ash policy path): list, toggle, set %, **flag age shown**
  (stale flags conspicuous), and an audit entry per change (who, flag,
  old→new — both humans and agents administer flags). A flag is deleted —
  row *and* code branch — once behavior is permanent; flags gate features,
  **never schema** (ADR-0010 rule).

## 3. Separation principle

Access rules decide **who can enter**; flags decide **what they see**. Flags
never become a shadow auth system; access rules never gate features.
Deliberately two mechanisms so both stay honest — access rules don't rot the
way flags do.

**Resolves**: open question #10. **Generalizes**: the private-beta invite
flow (v1 #385) is AccessRule email rows on prod.

## Amendment 2 (2026-09-01)

*(Consolidated in [ADR-0027](00027-admin-surface-ashadmin.md).)*

**Day-one admin surface is AshAdmin, not a hand-rolled LiveView.** AshAdmin
(ash-project/ash_admin) generates CRUD over Ash resources and runs entirely
through Ash actions — policies, validations, notifications all apply — so it
satisfies everything this ADR required of the admin surface (policy-gated
mutation, flag toggling and %) with zero build. Mounted admin-gated in prod,
open in dev; **actor impersonation** becomes the tool for verifying this
ADR's own policy decisions live. The curated flag view (toggle UX, flag age,
audit display) is deferred until generated CRUD annoys; audit entries per
change still land via resource changes.

## Amendment 3 (2026-09-01)

**Mailpit replaced by Swoosh's local adapter.** Non-prod environments
(local, staging, review envs) run `Swoosh.Adapters.Local` — mail captured
in-app, no SMTP server, no extra component. The mailbox UI and the
TestInbox JSON endpoint are **config-gated and admin-auth'd** (a public
mailbox viewer is an account-takeover machine — it displays live login
codes). Known trade-off: per-node memory storage. The multi-replica trigger's
pre-decided answer: swap the local adapter for a **DB-backed dev adapter**
(captured mails as Postgres rows, non-prod only; the gated TestInbox
endpoint reads the table — no test changes, works at any replica count,
survives redeploys). Cluster-RPC over libcluster is the acceptable
stopgap (it arrives with the second replica anyway); an external catcher
(Mailpit-class) returns only if SMTP-path testing is ever wanted. (Neither local
capture nor SMTP matches prod's Postmark-API delivery path — the login test
exercises mail-building + code generation, identical either way.)
