# ADR-00003: AshAuthentication; drop Authentik

**Status**: Accepted (amended — see Amendment 1)
**Date**: 2026-08-27

Authentik (~2 GB RAM + Helm release + Terraform branding + provider-skew risk)
was justified by a "self-host an OSS suite, unify behind OIDC" plan
(self-hosted feature-flag SaaS, dashboards, and friends). That strategy is
retired: feature flags, dashboards, and everything else they would have
fronted are native to the Elixir app — a `FeatureFlag` Ash resource +
LiveView admin; a paid APM for errors; and with one application there is
almost nothing left to SSO *into*.

**Decision**: **passwordless** — email one-time codes (no passwords) for
web/LiveView login, plus bearer tokens/PATs for machine access ([ADR-00019](00019-machine-first-api-cli-mcp.md)),
via AshAuthentication.

Why codes over magic links: the cross-device case decides it — the app is
open on the laptop while the email lands on the phone; a magic link opens
the app on the *wrong device*, a code travels by eyeball. Codes also dodge
magic-link's classic failure modes (email-scanner prefetch burning
single-use tokens, URL mangling by clients). Design constraints: 6-digit
code, 10-min TTL, single-use, hashed at rest, capped verification attempts
with backoff, send-endpoint throttling. Magic link is built into
AshAuthentication (v1 used it); the code variant is a small strategy
(community `ash_auth_code` exists — vet before adopting — or thin custom
over the same machinery).

Email is auth infrastructure: transactional sender with solid deliverability
(SPF/DKIM/DMARC) and monitoring; long-lived sessions (30–90 days,
remember-me by default) keep the email round-trip occasional. Login proves
inbox ownership by construction — welcome credits can only reach verified
emails (remaining abuse edge: disposable-domain handling).

## Amendment 1 (2026-09-01)

**Email provider: Postmark.** Chosen against the requirements this ADR
created: queryable outbound-messages API (enables the prod E2E TestInbox
adapter — read login codes from the Messages API, no test backdoors),
best-in-class deliverability with SPF/DKIM/DMARC per sender signature,
bounce/spam webhooks (implementing the "monitored" requirement above),
EU region, and an existing Swoosh adapter. Pricing: free tier is 100
emails/month — plausible coverage for early beta given 30–90-day sessions
(code sends are rare); $15/mo per 10k beyond. Config shape: Swoosh adapter
per environment (non-prod → `Swoosh.Adapters.Local`, gated mailbox +
TestInbox endpoint, ADR-0023 Am. 3; prod → Postmark);
server API token via the BWS operator ([ADR-00021](00021-secrets-bws-operator.md)).

**Consequences**: ~2 GB RAM returned to customer-instance capacity; social login
remains a cheap later add (pluggable strategies); managed SSO for *catalog
apps* (v1 #356, PocketID + Traefik forward-auth) remains a decoupled
post-beta product feature — dropping Authentik does not touch it.

## Amendment 2 (2026-09-07): non-prod mail is split by recipient — humans get real delivery

Amendment 1's environment table (non-prod → Local adapter) contained a
contradiction ADR-0023 Am. 3's own auth gate exposed during the #37
review: if staging captures **all** mail in-app, the only copy of a team
member's login code lives behind the **admin-auth'd** TestInbox — so
nobody can establish a first session (PAT minting needs a session too).
Staging's human population (ADR-0023's `fluxvale.com` allowlist) can
never bootstrap.

**Decision**: adapter selection is per-recipient on non-local
environments — **test accounts** (the `test@fluxvale.com` seed, ADR-0023)
capture via `Swoosh.Adapters.Local` (deterministic for E2E, zero quota
burn, no bounces to nonexistent inboxes); **all other recipients on
staging and review envs deliver via Postmark** (real inboxes — the
bootstrap path). Local dev stays Local-adapter-default (developers
read codes out-of-band via IEx; no gate to deadlock on). The TestInbox
(#22) keeps both planned backends: Local storage for captured test
mail, Postmark's Messages API for prod E2E. The recipient split lives
at the mailer seam (a few lines choosing capture vs. delivery), not in
per-environment config forks.
