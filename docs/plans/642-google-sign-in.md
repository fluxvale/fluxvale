# Plan: Sign in with Google alongside passwordless email (#642)

Status: **APPROVED — Terence via the PA, Nov 9 2026.** All decisions
D-library through D-policy settled as recommended (§12). One rider on
D-policy, which supersedes §8's original single-gate wording: S4's
**policy file changes** — the privacy/terms templates themselves —
are presented to the PA for Terence's sign-off BEFORE that PR merges;
S4's code and runbook merge under standing authority, the policy text
waits for his eye. The takeover analysis the issue demands is §4,
written out in full. Slices S1–S4 fan out per §13; this doc rides
S1's PR onto main (the #597 pattern).

Evidence base: the auth machinery as shipped — `VerifyAuthCode` /
`RequestAuthCode`, `User.get_by_email` / `get_by_address`, the
`user_emails` supersede/invitation semantics (#285, #287, #502), the
native POST fallback (#219/#623), `SessionController`, `AuthFlow`,
`AccessRules`, `FeatureFlags`, `ApiRateLimit` — plus assent 0.2.13's
source at tag (the exact version in our lock, read in
`deps/assent`), and the endpoint's session-cookie configuration.

## 1. The design in one paragraph

`/sign-in` grows a "Sign in with Google" button (a plain anchor — no
JavaScript, so the no-WebSocket resilience track holds by
construction). The anchor hits `GET /auth/google`, which builds an
OIDC authorization request against Google (scope `openid email`, PKCE
S256, `state`, `nonce`), parks the assent `session_params` plus the
validated `return_to` in the Phoenix session, and redirects. Google
authenticates the user and returns to `GET /auth/google/callback`;
the callback exchanges the code (PKCE verifier from the session),
assent verifies the ID token per OIDC Core (signature via Google's
JWKS, `iss`/`aud`/`exp`/`nonce`), and the operation resolves the
verified email to a user through the SAME admission ladder the
email-code arm runs — supersede, re-lookup, occupant, team-domain
JIT, `AccessRules` — then mints the standard 60-day token and writes
the session in one server-side hop. Existing users whose verified
email matches link automatically (a one-time flash says so, §4);
email codes stay exactly as they are.

## 2. Why this is safe to bolt on: identity IS the verified email

The whole system trusts one identifier: a verified `user_emails` row
([ADR-0003](../adr/00003-ashauthentication-drop-authentik.md);
#285 T3). The code/JIT sign-in path resolves an address to a user
through that table; an invited account's reservation lives in the
same table; and the session/token gates read it at user level. The
Google arm adds one new *proof* of that identifier (a Google-attested
`email_verified` claim instead of a burned 6-digit code) and changes
no storage: no identity table, no User columns, no migration. The
linking question (§4) is therefore only "is Google's attestation as
strong as our burned code?" — and for launch-scope risk, it is.

## 3. The flow, piece by piece

### 3.1 Library (D-library)

**assent, called directly** — `Assent.Strategy.OIDC`.

- It is **already in `mix.lock`** as a hard (non-optional) dependency
  of `ash_authentication` 4.15.1 — the pin, `jose` floor, and Req
  adapter support are paid for. We promote it to a direct exact pin
  (`{:assent, "0.2.13"}`) — the `ash`/`decimal`/`yaml_elixir`
  precedent for "in the lock, now used directly."
- Read at tag, 0.2.13 gives: `authorize_url/1` returning
  `%{url:, session_params: %{state:, code_verifier:, nonce:}}` when
  configured with `code_verifier: true` + a nonce; `callback/2` that
  validates `state`, exchanges the code with the verifier, fetches
  discovery at `base_url + /.well-known/openid-configuration`, and
  validates the ID token per OpenID Connect Core §3.1.3.7 — RS256 via
  the discovery's `jwks_uri`, issuer identifier vs the discovery
  `issuer`, `aud` vs our `client_id`, `azp`, `alg`, `exp`,
  `nonce` (constant-time), and `iat` presence. That is the entire
  cryptographic surface of this feature, and none of it is ours to
  get wrong.
- HTTP rides our existing `Req` through `Assent.HTTPAdapter.Req`.

Rejected:

- **`oidcc`** — a new dep tree (Erlang OIDC lib + its deps) for the
  same capability assent already provides at zero marginal lock cost.
  Its certified-coverage edge matters for being an *IdP-adjacent*
  generic client across many providers; we are one hard-coded,
  stable provider.
- **`AshAuthentication`'s OAuth2 strategy DSL** — the framework's
  own door, but this repo deliberately runs custom operations over
  the token machinery (no strategies exist on `User` today): the
  invitation wall (#502), `AccessRules`, the `AuthFlow` copy
  contract, and the native-POST resilience track all live in
  operation/controller land. The strategy would import its own
  routes, session handling, and upsert semantics and fight all four.
- **Hand-rolled over `Req`** — we would own discovery fetching,
  JWKS rotation, signature verification, and nonce/PKCE plumbing.
  More code, more ways to be wrong, for nothing assent doesn't do.

### 3.2 The two hops (D-flag, D-abuse)

`FluxValeWeb.GoogleController` beside `SignInController` /
`SessionController` in the anonymous browser scope:

1. **`GET /auth/google`** — refuses (redirect to `/sign-in` + honest
   flash) unless BOTH the `:google_sign_in` flag is on (declared in
   `FeatureFlags.@known_flags`, S3) AND
   `GOOGLE_CLIENT_ID`/`SECRET` are configured — the button renders
   under the same predicate, so the arm is invisible everywhere it
   can't work (dev/test/local default). Builds the authorize URL,
   stores `session_params` + `return_to` in the session (the Phoenix
   session cookie: signed, httpOnly — not encrypted, but its reader
   already holds the session, and httpOnly keeps the PKCE verifier
   out of JavaScript's reach; the `sign_in_email` precedent), and
   redirects to Google.
2. **`GET /auth/google/callback`** — pulls `session_params` from the
   session and hands code+params to assent. Assent fetches discovery
   before it checks anything, then validates `state` **before the
   token exchange** — a forged or replayed callback costs one
   outbound discovery GET and dies without a token request (the
   throttle of D-abuse bounds that too). On success the operation
   (§3.3) resolves the user; the session write is
   `store_in_session` in this one server-side hop (the token never
   rides a URL — the code in the callback URL is single-use, bound
   to our client id and PKCE verifier, and worthless once
   exchanged). Failures land on `/sign-in` with `AuthFlow`-owned
   copy; a `return_to` that survived the round trip is honored,
   `ReturnPath.safe`-validated as always.

**Rate limiting (D-abuse):** a per-IP fixed window (default 10/min,
config-overridable — `ApiRateLimit`'s floor-bucketing math and
config-! posture, in a small ETS table owned by the controller
module) counting both hops. ETS is exact here: the platform
Deployment is `replicas: 1`. **The per-IP key must come from
`X-Forwarded-For`, not `conn.remote_ip`:** behind Traefik the
endpoint's `remote_ip` is the proxy pod IP (the endpoint rewrites
nothing), so a `remote_ip` key would be one global bucket. The app
is reachable only through exactly one proxy hop in every deployed
environment, so the extraction is the rightmost XFF entry — the
address Traefik appended — and a client-forged XFF prefix cannot
influence it; local dev (no proxy) falls back to `remote_ip`.
Revisit trigger: a second proxy layer lands. Browser-shaped answer
on overflow — redirect back to `/sign-in` with the same "wait a
minute" register the email throttle uses, never a bare 429 page.
The outbound budget this bounds: one discovery GET per authorize
hop; a successful sign-in adds discovery + token exchange + JWKS on
the callback (four outbound requests total, human-paced); a forged
callback, just the one discovery GET.

### 3.3 The operation (D-admission, D-storage)

`FluxVale.Identity.Operations.SignInWithGoogle`, exposed as
`Identity.sign_in_with_google/1` — one input (the assent-verified
user claims map), one output shape the web layer maps through
`AuthFlow`:

```
{:ok, user, token} | {:error, :not_allowed | :invitation_required |
 :invite_pending | :email_not_verified | :provisioning_failed}
```

(`:unauthorized` and assent-level failures are the CONTROLLER's
error set — they happen in the OIDC hop before any claims exist.)

1. **Strict `email_verified` gate first**: anything but literal
   `true` refuses `:email_not_verified` — no account lookup happens
   for an unverified claim (§4). A missing or malformed email is the
   same refusal (an unusable claim is an unverified claim).
2. `AccessRules.ensure_allowed(email)` — the same address gate the
   code-send runs, before anything else burns a round trip.
3. **Resolve**: `get_by_email` (verified rows only) → sign-in. This
   IS the auto-link: a Google-attested inbox proves the identifier
   our system already trusts.
4. **Not found → the `VerifyAuthCode` ladder, rung for rung** — the
   Google proof stands in for the burned code: supersede pending
   claims (unproven; invited reservations exempt by the action's own
   filter, #287), **re-run `get_by_email`** (a concurrent
   `VerifyEmail` may have flipped the claim verified between the
   supersede and now — resolving to its owner instead of forking a
   second account is the whole point of the re-lookup), then the
   occupant lookup decides — `:invite_pending` for an outstanding
   invite (the emailed link is the credential), the wall
   (`:invitation_required`) for retired invitations and uninvited
   addresses, JIT create **only** on the `@fluxvale.com` team
   bypass, with the same create-collision handling as the email arm
   (a `unique_address` hit in the residual window resolves, never
   forks), firing the same `signup_event` telemetry.
5. `AccessRules.ensure_allowed_user(user)` at the mint — the
   user-level gate the token branch closes at `SessionController`
   (#26). Adding it here is deliberately stricter than the native
   email+code branch (whose re-entry protection lives inside the
   verify): one hop, both gates.
6. Mint via `AshAuthentication.Jwt.token_for_user/1` — the same
   token store, revocation, and 60-day TTL as every session.

**What we store from Google (D-scopes):** scope is `openid email` —
no `profile`. We read `email` and `email_verified`, and `sub` only
to exist in the round trip (never persisted, never logged). Name,
picture, locale are neither requested nor kept; the account shape is
identical to an email-code signup (username derived from the
address, personal org provisioned). The privacy paragraph (§8) stays
true because the data path stays minimal. The Google button still
shows the standard "G" mark per Google's branding rules (inline SVG,
official colors — no Google script is needed for the server-side
flow).

**No identity table (D-storage):** nothing records "this user has
used Google." Every Google sign-in re-proves the address fresh; the
linking is implicit in the shared identifier. Zero migration, zero
new resources, and the privacy story is honest. Revisit trigger: a
connected-accounts settings surface, or a second IdP — then a
`user_identities` row (`provider`, `provider_uid`, `user_id`) earns
its keep and D-linking gets re-run for multi-provider semantics.

### 3.4 Surfaces

There is no separate register surface to place a button on — JIT
signup means `/sign-in` **is** registration (the landing CTAs and
the catalog's gated deploy CTA all land there). So: the button lives
on the sign-in LiveView's `:email` step, full-width below "Send
code" — below the invitation hint too (the hint sits above the
button in the current markup), so the pairing reads "code or Google,
either starts your account" at the action line. The `:code` step
stays email-only (the visitor is mid-flow). Native fallback N/A:
the anchor is already a plain GET. Screenshots (light+dark) ride the
surface PR per the owner convention.

### 3.5 Machine surfaces (D-cli)

None. No JSON:API route, no CLI/MCP surface, no OpenAPI schema
delta — and so no `cargo xtask openapi --check` regeneration ripple
in `apps/cli` (the CLI's generated types are untouched by a web-only
arm). The device flow is arm-agnostic already (approval rides
whatever browser session the human has), so `flux login` works for
Google users without any CLI change.

## 4. D-linking: the auto-link analysis, written out

**Decision: auto-link on Google-verified email match at first Google
sign-in. No confirmation interstitial, no identity row. A one-time
flash on the first linked sign-in says what happened (adopting
OWASP's notification recommendation — see below).**

The classic danger of auto-linking federated identities into
passwordless/email accounts is account takeover via IdP account
creation: an attacker creates an IdP account bearing the victim's
email address and lets auto-link graft it onto the victim's existing
account. OWASP's [Authentication Cheat Sheet — Secure Federated
Account Linking](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html#secure-federated-account-linking)
warns exactly this: *"Do not automatically link accounts solely
because their email, preferred_username, or other profile attributes
match"* (because such claims "are not guaranteed to be unique or
stable") and *"Notify the user when an identity is added."* We adopt
the notification (the first-link flash) and deliberately diverge from
the first clause. The divergence is defensible only on this design's
specific legs — the guardrails below are what keeps them true:

- **The IdP is fixed: Google.** Not user-supplied discovery, not a
  provider configured by URL an attacker can influence. The one
  escape hatch is `GOOGLE_OIDC_ISSUER`, an operator-held env override
  for tests and staging redirection of the same hard-coded arm —
  inside the operator trust boundary that already holds the client
  secret (whoever sets env against Google can already impersonate
  the arm; the override adds nothing to their reach). A user can
  never influence which IdP is consulted. Adding a second provider
  re-opens D-linking, not this section.
- **The matched attribute is the identifier itself, strictly
  attested.** OWASP's warning is about *profile attributes* matched
  across arbitrary IdPs whose email claims may be unverified or
  attacker-creatable. Here the match key is the system's primary
  identifier, and the strict gate (§3.3 step 1) drops every claim
  whose `email_verified` is not literal `true` — before any lookup.
  Google only puts an address on an account it controls or verified:
  `@gmail.com` addresses ARE the account; a non-Google address
  becomes a Google account's email only after Google's own
  verification flow. The attacker-creatable-email shape never
  reaches resolution.
- **The strength equivalence holds:** our burned 6-digit code proves
  "this human received email at this address within 10 minutes";
  Google's attestation proves "this human controls the Google
  account that owns this address." For an `@gmail.com` victim
  address — the overwhelmingly common case — the Google proof is the
  *stronger* one (session-bound, phishing-resistant vs. a code that
  can be forwarded).
- **Admission parity (§3.3 step 4) closes the creation side:**
  linking grants no account the email arm wouldn't grant. The
  invitation wall and team-domain JIT apply identically, so a Google
  account is not a side door around admission.
- **OWASP's uniqueness/stability rationale doesn't bite here.**
  Uniqueness: an address belongs to at most one account at a time
  (`user_emails.unique_address`). Stability: there is no persisted
  link to go stale — the implicit link follows the identifier, and
  the email-change edge is documented honestly (§4 table). The sheet's
  "require an authenticated session before adding linked identities"
  governs explicit linking surfaces that save an identity row; this
  design has no linking surface and saves no row — the §4
  strength-equivalence argument is what carries the access decision.

**What would make it unsound (the guardrails, restated as failure
conditions):**

1. Accepting unverified claims — the strict `true` gate. Non-negotiable.
2. Multiple/arbitrary IdPs with the same auto-link — blocked: one
   provider, in code. A second IdP must re-run this analysis
   (per-provider verified-email semantics differ).
3. If our primary identifier ever stops being the verified email
   (username-first login, phone login) — then email match stops
   being identity equivalence and linking must become explicit.
4. If Google semantics drift (e.g. permitting unverified primary
   emails again) — the strict gate still refuses; worst case is the
   arm degrading to refusal, never to takeover.

**Edge cases:**

| Case | Behavior |
|---|---|
| Google claim `email_verified` not `true` | `:email_not_verified` — "your Google account's email isn't verified; use email codes" + Google's own verification hint copy |
| Address owned by a live account | Sign-in (the link), with the one-time first-link flash: "Signed in with Google — this account's email is <address>" |
| Address has a pending claim by another account | Claim superseded (unproven), re-lookup, then the ladder — exactly `VerifyAuthCode`; invited reservations exempt (#287) |
| Address is an outstanding invite | `:invite_pending` — the emailed accept link is the credential, exactly like a code verify at an invited address |
| Retired (withdrawn/expired) invite | `:invitation_required` — the wall copy |
| Unknown address, non-team domain | `:invitation_required` — same wall, same copy |
| Unknown address, `@fluxvale.com` | JIT create, `signup_event` fired — the team bypass, same as codes |
| Gmail dot-variants (`a.b@` vs `ab@gmail.com`) | Distinct strings, distinct accounts. Google's ID token carries the address in the form Google stores — which may differ in dot placement from what the user typed at email signup; we do not normalize dots (documented, tiny, honest) |
| Address denied by `AccessRules` | `:not_allowed` at step 2; user-level gate again at mint |
| User later changes their Google account's email | Next Google sign-in resolves the NEW address (other account, or the wall); email codes to the original keep working — the implicit link follows the identifier, never the person |
| Google down / creds revoked | Controller-level `:unauthorized` copy: "Google sign-in is unavailable — use an email code" (the always-on fallback, §5) |

## 5. The always-on fallback guarantee

The Google arm is strictly additive: no existing email-code
*behavior* changes — the shared `AuthFlow` module and the sign-in
LiveView gain additive clauses, and every guarantee the email arm
owns (throttle, expiry, attempt cap, the AccessRule gate, the
native POST fallbacks) is untouched. Email codes remain reachable
and functional in every state the Google arm can be in —
unconfigured (hidden button), flag-off (hidden button), Google
outage (honest error copy naming the email alternative), throttled
(the email form is a different window). The one-way degradation is a
hard requirement of this issue: **no state exists in which email
codes work worse than today.** Tests pin it: the sign-in LiveView
suite runs green with the Google arm on, off, and unconfigured.

## 6. Env config and the owner's step

`config/runtime.exs`, the `HITPAY`/`POLAR`/`POSTMARK` shape:

- `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` — BWS-injected env in
  the cluster ([ADR-0021](../adr/00021-secrets-bws-operator.md)),
  never committed; nil/`""` (empty-Secret shape) = unconfigured.
- `GOOGLE_OIDC_ISSUER` — optional operator override, default
  `https://accounts.google.com`. Exists so the mock provider (§7)
  and any staging experiment point elsewhere without release surgery.
- Redirect URI derives from the endpoint (`PHX_HOST`):
  `https://<host>/auth/google/callback`. No env var to drift.

**Owner-held final step (called out, not automatable):** Terence
creates the OAuth client in Google Cloud Console — APIs & Services →
Credentials → OAuth client (Web application), authorized redirect
URI `https://fluxvale.com/auth/google/callback` (plus the staging
host), consent screen external with scope `openid email`; then parks
the client id/secret in BWS. Until that lands, the button simply
does not render (flag/creds predicate) — nothing half-configured
ships. Internal runbook with the click-path:
`docs/runbooks/google-oauth-client.md` (S4). Launch note: while the
consent screen stays in testing, Google caps users to 100 test
users — flipping it to production (no sensitive scopes, so no
extended verification) is a launch-day checklist item in that
runbook.

## 7. Tests: a mock OIDC provider

`test/support/oidc/provider.ex` — a real Bandit server on
`127.0.0.1:<random>` (Bandit is already a direct dep): serves
discovery (issuer = its own base URL, `jwks_uri`, auth/token
endpoints; no userinfo endpoint — assent then reads claims from the
ID token alone), `/authorize` (302 back to the caller's
`redirect_uri` with a code, remembering the received
`code_challenge` and `nonce`), `/token` (RS256-signed ID token
minted with a JOSE RSA key generated at suite start, PKCE
S256-verified against the remembered challenge), and the JWKS.
Point the app-env issuer at it; assent runs its full validation
chain — signature, issuer, audience, expiry, nonce — against the
mock. Nothing in `lib/` knows the provider is fake (no test
backdoors; the config seam is the same `GOOGLE_OIDC_ISSUER` override
staging would use).

Matrix: every row of §4's edge table, at operation level (S2) and
again through the controller hops — state mismatch, code replay,
`email_verified` variants, throttle window overflow, flag/creds
refusal, return-path round trip, and the §5 fallback pin. The
operation's seams stay out of it: assent is injected whole via
config, the way the mailer adapter is.

## 8. Policy copy (D-policy) — drafted for the owner's review

**Two gates, per the PA's Nov 9 rider:** plan approval settled the
*decisions*; the final policy **file text** in S4 still goes to the
PA for Terence's eye BEFORE that PR merges. The drafts below are
what S4 lands if he approves them as-is; S4's code and runbook
merge under standing authority either way. "Last updated" flips at
merge.

Privacy policy, new card after "What we collect" (house copy rules —
plain sentences, no em-dashes, no semicolons):

> **Sign-in with Google**
>
> You can sign in with a Google account. When you do, Google tells
> us your email address and confirms that Google has verified it. We
> ask for nothing else, and we do not send Google any data about
> you. We store no Google profile, no name, and no picture. Your
> email-code sign-in keeps working either way.
>
> Google is an identity provider for sign-in. How Google handles its
> own data is described in Google's privacy policy.

Terms of Service, a two-sentence addition to the account section:

> You may sign in with a Google account. Keeping that Google account
> secure is your responsibility, and email-code sign-in remains
> available to the email addresses you have verified with us.

`docs/public/getting-started/account.md` gains a short "Sign in with
Google" section (both doors, one account) — the public-docs surface,
not policy wording.

## 9. What deliberately does NOT change

The API schema, CLI types, MCP tools, device flow, PAT machinery,
invite emails, `AuthCode`, the native POST fallbacks, and every
email-flow guarantee. No DB migration at all.

## 10. Telemetry

JIT creates fire the existing `signup_event` (same semantic, both
arms). One new event, `[:flux_vale, :identity, :google_sign_in]`
with `count: 1` and `%{outcome: atom}` — the abuse/health signal
for the arm, emitted from the operation. No PII in metadata.

## 11. Risks

- **Google consent-screen state at launch** — owner checklist item
  (§6), timing risk only.
- **assent pin ceiling** — the 0.2.x line is ash_authentication's
  constraint (`> 0.2.0 and < 0.3.0`); 0.2.13 is the locked member,
  and a 0.2.14 fix rides a normal pin bump. A 0.3.x-only fix
  revisits the pin with an AA upgrade. Exact-pin discipline makes
  that a deliberate diff.
- **Invitation-wall lift at public launch** — when the wall lifts,
  BOTH arms' admission must lift together (they share the
  `VerifyAuthCode` ladder; `SignInWithGoogle` mirrors it). Named
  here so the launch owner edits both, once.
- **Gmail dot-variants** — documented (§4), not normalized.
- **XFF-derived rate-limit key** — sound at exactly one proxy hop
  (every deployed environment today); the §3.2 revisit trigger fires
  if a second layer lands.

## 12. Decision list (as approved by Terence via the PA, Nov 9 2026)

- **D-library — assent 0.2.13, direct.** In the lock via
  ash_authentication; full OIDC Core ID-token validation incl.
  PKCE/nonce; zero new deps. `oidcc` = new tree for the same job;
  the AA strategy fights the house auth shape; hand-rolled owns
  crypto we shouldn't.
- **D-linking — auto-link on verified-email match, strict
  `email_verified == true`, no identity table, first-link flash.**
  §4: one fixed trusted IdP, Google-attested address = our
  identifier; unverified claims refused pre-lookup; OWASP's
  notification recommendation adopted as the flash; admission
  parity closes the creation side. Unsound-if list kept as
  guardrails.
- **D-admission — identical ladder to email codes.** Invitation
  wall, `:invite_pending`, team-domain-only JIT, `AccessRules` at
  request and user level. Google is never a side door.
- **D-scopes — `openid email`, nothing else.** No profile/name/
  picture; account shape identical to email signup; privacy copy
  stays minimal because the data path is.
- **D-storage — no `user_identities` in v1.** The verified email is
  the identity; revisit on a connected-accounts surface or second
  IdP.
- **D-flag — `:google_sign_in` feature flag (declared in
  `@known_flags`, S3) AND creds-present gate for the button.**
  Fail-closed, instant shutdown lever (`pocketid_sso_wiring`
  precedent); unconfigured = hidden.
- **D-abuse — per-IP fixed window (10/min default, ETS,
  ApiRateLimit's bucketing, XFF-rightmost key per §3.2) on both
  Google hops**, browser-shaped refusal copy; bounds the outbound
  budget §3.2 tallies; exact at `replicas: 1`.
- **D-cli — no dedicated Google surface in v1.** Device flow is
  arm-agnostic; CLI untouched; no schema/CLI-type ripple.
- **D-policy — privacy + terms paragraphs drafted in §8**, two
  gates per the rider (plan approval settled decisions; S4's policy
  text gets Terence's pre-merge sign-off); runbook for the Google
  Cloud client step (§6).

## 13. Slices

Each lands green (`cd apps/platform && mix ci`), one PR per slice,
#642 referenced without a closing keyword until the last.

- **S1 Docs + pin** — this plan, [ADR-0003](../adr/00003-ashauthentication-drop-authentik.md)
  Amendment 4 (Google arm recorded: assent, linking stance, scopes),
  assent promoted to a direct exact pin. *Done when:* docs render,
  links verify, `mix ci` green with the pin.
- **S2 Core operation** — `Operations.SignInWithGoogle` + the
  `GoogleOIDC` assent seam + domain delegates + the mock provider in
  `test/support` + the full op matrix (§7). *Done when:* every §4
  edge row has a green test; telemetry asserted; no `lib/` mention
  of "google" outside Identity.
- **S3 Web surface** — runtime config, `GoogleController` (both
  hops, throttle with the XFF-rightmost key, flag/creds gate),
  routes beside `/auth/session`, `:google_sign_in` declared in
  `FeatureFlags.@known_flags`, button on `/sign-in` `:email` step,
  `AuthFlow`'s Google copy arm, LiveView + controller tests,
  screenshots light+dark. *Done when:* the §5 fallback pin passes;
  state-mismatch/replay/throttle tests green; PR carries
  screenshots; no API schema delta (stated).
- **S4 Policy + runbook** — §8 copy into privacy/terms, account.md
  section, `docs/runbooks/google-oauth-client.md` owner click-path.
  *Done when:* policy tests pin the paragraphs; docs lint green;
  "Last updated" flips; **the policy text has Terence's pre-merge
  sign-off via the PA (the rider)**. Closes #642.

Order: S1 → S2 → S3 → S4; S2 and S3 parallelizable after S1 only if
S3 takes S2's operation signature from this plan (the seam in §3.3
is the contract).
