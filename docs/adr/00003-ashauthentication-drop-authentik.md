# ADR-00003: AshAuthentication; drop Authentik

**Status**: Accepted (amended — see Amendments 1–4)
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
contradiction [ADR-0023](00023-day-one-gates.md) Am. 3's own auth gate
exposed during the #37 review: if staging captures **all** mail in-app, the only copy of a team
member's login code lives behind the **admin-auth'd** TestInbox — so
nobody can establish a first session (PAT minting needs a session too).
Staging's human population (ADR-0023's `fluxvale.com` allowlist) can
never bootstrap.

**Decision**: adapter selection is per-recipient on non-local
environments — **test accounts** (the `test@fluxvale.com` seed, [ADR-0023](00023-day-one-gates.md))
capture via `Swoosh.Adapters.Local` (deterministic for E2E, zero quota
burn, no bounces to nonexistent inboxes); **all other recipients on
staging and review envs deliver via Postmark** (real inboxes — the
bootstrap path). Local dev stays Local-adapter-default (developers
read codes out-of-band via IEx; no gate to deadlock on). The TestInbox
(#22) keeps both planned backends: Local storage for captured test
mail, Postmark's Messages API for prod E2E. The recipient split lives
at the mailer seam (a few lines choosing capture vs. delivery), not in
per-environment config forks.

## Amendment 3 (2026-11-07): invites are pre-provisioned users

#478 made invitation a gate resource consulted at sign-in. #502 retires
that gate: the admin already knows exactly who is being admitted, so
the invite creates the User directly (inert until acceptance) and the
emailed accept link hands the account over. The link carries a one-time
token, stored only as its SHA-256 hash and consumed on use. This is
the URL-credential carve-out [ADR-0042](00042-user-created-organizations.md)
pioneered for membership invites: session tokens never appear in a URL
(they ride the `POST /auth/session` body), and the one-time invite
token is the only URL credential. Acceptance runs the first-login
bootstrap and mints the session through that same POST.

## Amendment 4 (2026-11-09): Google sign-in as a second proof of the same identifier

#642 adds "Sign in with Google" beside the email-code flow — planned in
[docs/plans/642-google-sign-in.md](../plans/642-google-sign-in.md),
which owns the full analysis; this amendment records the stance.

The Google arm adds a **proof**, not an identifier: OIDC code flow
with PKCE (nonce, state) via **assent** — already in the lock as a
hard dependency of AshAuthentication, promoted to a direct exact pin —
with scope `openid email` only: nothing beyond the address is kept
(`sub` exists in the round trip and is never stored; no profile
claims), so the account shape and the stored-data posture are
unchanged (the privacy *disclosure* gains a Google card, #642 S4). The
ID token's `email_verified: true` claim,
strictly gated, is accepted as equivalent proof of inbox control to a
burned 6-digit code: **sign-in auto-links on verified-email match, no
identity table** — the `user_emails` row that every other flow
resolves through IS the link. The OWASP divergences (link-on-match,
no notification) are deliberate and argued in the plan's §4. Admission
is at least as strict as the email
arm (the invitation wall, `:invite_pending`, team-domain-only JIT,
`AccessRules` at request and — beyond the native code branch — user
level at mint): Google is never a side door around
admission. A `:google_sign_in` feature flag plus credentials presence
gate the surface, fail-closed; email codes remain the always-on
fallback in every state the Google arm can be in.
