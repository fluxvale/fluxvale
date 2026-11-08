# Plan: seamless PocketID SSO for new instances (#597)

Status: **APPROVED — Terence, Nov 8 2026.** All decisions D1–D8
settled as recommended (§10 records the one amendment: the custody
audit trail is first-class in S2). Slices S1–S6 fan out per §8;
this doc rides S1's PR onto main.
Evidence base: the shipped PocketID image probed live (transcript in §2),
the v2.19.2 source at tag, and the repo's own code. #511's research and
#529's shipped v1 are reconciled in §3.

## 1. The design in one paragraph

When an org has a PocketID instance the platform holds an API key for
(pasted once by the owner, stored as a cluster Secret, never in
Postgres), the deploy wizard for an OIDC-capable app offers "Sign in
with your Pocket ID" on the configuration step. Accepting it means the
platform mints an OIDC client in that PocketID via its REST API at
instance create — after the slug exists (callback URL known), before
the deploy job runs — and injects the client credentials into the
app's deploy-time env exactly like the manual #529 inputs. The
instance page then carries an SSO card with the live wiring state,
plus a post-hoc connect path for instances that predate the PocketID,
secret rotation, and disconnect. v1 ships Vaultwarden end to end; more
apps join by catalog declaration.

## 2. The client-provisioning answer, with evidence

**Yes — our shipped version (2.19.2) creates OIDC clients
programmatically.** What it takes: one **admin API key** (personal,
user-scoped, `X-API-KEY` header) minted **by a browser session**. There
is no service account, and the platform cannot bootstrap a key itself.

Transcript — `ghcr.io/pocket-id/pocket-id:v2.19.2` (the catalog's exact
image), throwaway pod in the local k3d cluster, port-forwarded:

```
# First-boot state: GET availability (this is also our mid-setup probe)
GET /api/signup/setup                      -> 204 (admin not yet claimed)

# First-boot contract (public, one-time, rate-limited; email required in 2.19.2)
POST /api/signup/setup {"username":"probe-admin","email":...}
  -> 200 {"id":...,"isAdmin":true,...} + session cookie
GET /api/signup/setup                      -> 404 setup_not_available

# Mint an API key — SESSION cookie required
POST /api/api-keys {"name":"fluxvale-platform-probe","expiresAt":...}
  -> 201 {"apiKey":{...},"token":"zpPvw4..."}        (token shown once)

# THE ANSWER: create an OIDC client with the key
POST /api/oidc/clients {"name":"vaultwarden",
      "callbackUrls":["https://vw.example.com/identity/connect/oidc-signin"],
      "isPublic":false}   [X-API-KEY]
  -> 201 {"id":"080258e5-...","pkceEnabled":false,...,
          "createdSecret":{"secret":"3QRT4i5W...","prefix":"3QRT",...}}

# Rotation: a SECOND active secret, then revoke the old one (zero-downtime)
POST /api/oidc/clients/<id>/secrets [X-API-KEY]  -> 201 {"secret":"VOwUjdsh..."}
DELETE /api/oidc/clients/<id>/secrets/<sid>      -> 204

# Custody boundary, verified live
POST /api/api-keys [X-API-KEY] -> 403 api_key_auth_not_allowed
```

Source-verified at tag v2.19.2 (`backend/internal/authz/scope.go`):
API keys are delegated credentials holding the user's scopes (admin →
all), **but** `account:api-keys:create` is session-only by design — a
key can never mint keys. `oidc-clients:write` is delegated-grantable,
so the key above can create clients, manage their secrets, and set
allowed groups (`PUT /api/oidc/clients/:id/allowed-user-groups`). Two
more contract facts from the DTOs: the create response is the **only**
response that reveals a secret, and `POST .../secrets` accepts a
**caller-supplied** secret (≥16 printable ASCII) — the platform can
generate its own secret and never depend on capturing PocketID's
response. Discovery (`/.well-known/openid-configuration`) answers the
issuer as exactly `APP_URL`, which our deployer already seeds from the
instance's public URL.

Consequences for the design:

- **No service account exists or is needed.** The org owner creates one
  admin API key in the PocketID UI and pastes it into FluxVale once.
- **First-boot stays the user's.** The platform will not drive
  `POST /api/signup/setup`: that would make the platform the admin
  identity's owner — a custodial identity the product doesn't want.
- **Blast radius of the held key is full admin** over that PocketID.
  Custody discipline in §4.3; it's Terence's decision D1.

## 3. Reconciliation with prior work

- **v1 (#529, shipped) stays.** Docs + catalog env inputs are the
  manual fallback and the base this builds on; nothing is reverted.
- **v1.5 (read-only SSO card) is superseded** by the instance-page card
  in slice S5 — it carries v1.5's content (discovery URL, callback URL)
  plus the live wiring state and actions.
- **v2 (connect flow) is folded and verified**: the custody + mint +
  env-wiring shape is this plan, now checked against the real API
  surface instead of docs. The spike's open custody question is
  answered (§4.3).
- [ADR-0016](../adr/00016-deferred-triggers.md)'s "PocketID managed SSO"
  row stays accurate until implementation lands; the landing PR amends
  it to shipped-with-#597.

## 4. The flow, piece by piece

### 4.1 Detection

An org "has an active PocketID" = a PocketID instance row in the org
that is deployed (has a namespace) and not `:deleting`/`:lost`, with
`exposure == :public` (a private PocketID serves no issuer — ADR-0038
§4's dead-links rule). One org-scoped read joins through
`app_version → app` on slug `pocket-id`; a dedicated read action (the
`list_for_organization` precedent) keeps it one query.

**Offer-ready** additionally requires custody (§4.3). **Mid-setup**
(admin not claimed yet) is detected by probing the PocketID's own
public endpoint `GET /api/signup/setup` — 204 means unclaimed, 404
means done (verified in §2). The probe is a lazy server-side call at
wizard load with a short timeout; failures render as " Pocket ID not
reachable" copy, never as a broken wizard.

### 4.2 The offer (wizard UX)

Lands on the deploy wizard's **configuration step** (step 2), above the
manual env inputs, only when ALL hold: the app version carries an
`oidc_wiring` recipe (§5), the target org has a public PocketID, and
custody is ready. It is a **toggle, default off** (D7) — prefilling
credentials into a new app is a behavior change users must see happen.

States of the card:

- ready → "Sign in with your Pocket ID — <pocketid-url>. We'll create a
  <app> client in it automatically." Toggle on hides the manual SSO_*
  inputs for this app (they're the collapsed fallback).
- mid-setup → "Finish setting up your Pocket ID first" + link to the
  PocketID instance page (its first-run guidance already covers it).
- no custody → "One-time: let FluxVale manage sign-in clients" + link
  to the custody card on the PocketID instance page.
- multiple PocketIDs with custody → a picker, defaulting to the most
  recently deployed; the choice is recorded in the wiring.

The API/CLI path is the same seam as the retrofit (§4.6), so the wizard
is sugar over one operation, not a parallel implementation.

### 4.3 Custody (the held API key)

Rides the **Tailscale-token discipline exactly** (ADR-0040 §5,
`SetAccessApiToken` — the repo's one precedent for org-level
third-party credentials):

- intake card on the **PocketID instance page**: owner pastes the key;
  the platform **verifies it live** (`GET /api/oidc/clients` with the
  key) before accepting;
- stored in a K8s Secret in the platform-owned access namespace; the
  row carries the **Secret's ref, never the key**; no read-back
  surface; never logged;
- **owner-only** write (the `ActorIsOrganizationOwner` predicate);
- the key's expiry is shown on the card (PocketID keys carry
  `expiresAt`; expiry emails are PocketID's own feature);
- failure modes render honestly: invalid key, unreachable instance.

What the platform does with the key is visible to the org: every mint
lands in PocketID's own audit log attributed to the key's user, and
clients are named `FluxVale · <app name>` so they're recognizable in
the PocketID admin UI. The owner can revoke the key in PocketID at any
time; the platform's cards then degrade to "key rejected — re-paste",
never silently.

### 4.4 Issuer derivation

The issuer is the PocketID instance's public URL —
`https://<slug>.<instances_base_domain>` — the same value the deployer
seeds into `APP_URL` (the `instance_url_env` machinery, #73). At wiring
time the platform **fetches the discovery document** and uses the
issuer string it returns verbatim (catches drift; PocketID returns
`APP_URL` exactly, and Vaultwarden's `SSO_AUTHORITY` must equal the
issuer with no trailing slash). Custom-hostname URL selection stays the
declared S5 residual it already is (`deploy_instance.ex` models only
the default hostname). Wiring refuses a private PocketID (§4.1).

### 4.5 Provisioning + per-app config injection

Sequencing exploits the wizard's existing two-step: `create` (row +
slug + default hostname minted) **→ wiring → `deploy!`**. Nothing in
`DeployInstance` changes.

The wiring operation (`FluxVale.Infrastructure.Operations`,
org-member-gated like every instance write):

1. read custody for the chosen PocketID; read the app version's recipe;
2. fetch discovery (issuer check, reachability);
3. `POST /api/oidc/clients` with name `FluxVale · <instance name>`,
   callback = `<new instance's public URL> + oidc_callback_path`,
   `pkceEnabled` from the recipe, a platform-generated secret (§2),
   not group-restricted (= all users; group curation is a later
   refinement — D8 note);
4. merge `SSO_*`-shaped env per the recipe onto the instance's
   `env_vars` (a system update touching only the recipe's keys — user
   env is never altered), and record the wiring row: which PocketID
   instance, which client id, which secret ids, when;
5. the caller proceeds to `deploy!`; the k8s Secret ships the env
   snapshot including the SSO keys.

**Failure posture (D3): the app's deploy never depends on the IdP.**
If any wiring step fails (PocketID sleeping — backends get 503 while
waking, ADR-0036 — or down, key rejected), the instance remains
deployable without SSO: the wizard surfaces "Pocket ID unreachable —
retry wiring, or continue without sign-in," the instance page carries
the same retry. No silent partial states: wiring either recorded or
absent.

### 4.6 Retrofit, rotation, disconnect (instance-page SSO card)

- **Retrofit** (app instance predates the PocketID): the SSO card on a
  recipe-carrying instance lists the org's ready PocketIDs and offers
  Connect. Same wiring op, plus one new primitive: for a **deployed**
  instance, applying an env change means updating the instance's k8s
  Secret and rolling the Deployment (the env-is-a-deploy-snapshot
  constraint, named in #511 and unchanged). Scoped narrowly: the
  primitive rewrites only the recipe's keys, never arbitrary env
  (D5 — this is deliberately not a general env-editing feature).
- **Rotation**: `POST /clients/:id/secrets` (new secret), env update +
  rollout restart, then `DELETE` the old secret — the zero-downtime
  sequence verified in §2. One button, one explanation.
- **Disconnect**: delete the PocketID client (best-effort), strip the
  recipe keys from env, rollout restart. Copy states the app's local
  login survives (verified per-app in #511: every app keeps one).
- **Confirmation** (the success state the issue asks for): the card
  shows "Sign-in wired to Pocket ID at <url> — client <name>, created
  <date>, all PocketID users allowed", with Rotate / Disconnect.

On instance **delete**, teardown best-effort deletes the PocketID
client (D6); failure is tolerated and the client remains visible (and
deletable) in PocketID's own admin.

## 5. Catalog metadata extension

One new nullable attribute on **AppVersion** (blueprint land, the
`oidc_callback_path` precedent — per-version so an upstream breaking
change never re-wires older instances), a new Ash type
`FluxVale.Catalog.Types.OidcWiring`:

```yaml
oidc_wiring:            # presence = OIDC-capable + the wiring recipe
  kind: env             # env | in_app (in_app = mint + show values, v2)
  issuer_env: SSO_AUTHORITY
  client_id_env: SSO_CLIENT_ID
  client_secret_env: SSO_CLIENT_SECRET
  enabled_env: SSO_ENABLED      # optional; set true when wired
  pkce: true
```

- `kind: env` — the platform injects everything at deploy (Vaultwarden,
  ActualBudget when it ships).
- `kind: in_app` — the platform mints the client and the card shows
  copy-ready values + the app's own admin-screen path (Forgejo, Kavita,
  Memos). Not in v1; the type carries the union so no migration later.
- The recipe's env names must exist in that version's
  `configurable_env_vars` (secret-typed for the secret env) — a
  validation at write time, so catalog data can't drift.
- The JSON API's app-version routes gain the field (public read; no
  secrets — names only, the `oidc_callback_path` stance).
- Vaultwarden 1.37.5's seed carries the `env` recipe above (its
  `configurable_env_vars` already declare the SSO_* inputs from #529 —
  the recipe names them; wiring sets them server-side, bypassing the
  form).

## 6. Edge cases, concretely

| Case | Behavior |
|---|---|
| PocketID mid-setup (no admin yet) | Offer shows finish-setup state + link; probe is `GET /api/signup/setup` (§4.1) |
| PocketID sleeping at wiring time | Wiring fails visibly (503-to-backends, ADR-0036); retry or continue without SSO; offer copy recommends always-on (existing #529 copy) |
| PocketID private | Not detected as offer-eligible; retrofit card explains "must be public" |
| App created before PocketID | Retrofit path (§4.6) |
| Multiple PocketIDs per org | Picker at offer + card; wiring records which instance served it |
| Held key revoked / expired | Cards degrade to "key rejected — re-paste" (owner-only); no silent wiring failures; PocketID's own expiry email also fires |
| Secret rotation | Two-secret zero-downtime sequence (§4.6) |
| PocketID destroyed while wirings live | Cards show "Pocket ID gone — clear wiring"; clear = strip env + restart. Destroy-time warning on the PocketID itself when other instances reference it is a v1.5 nicety (listed, not sliced) |
| Owner changed PocketID `APP_URL` / issuer drift | Wiring-time discovery fetch catches it; card shows issuer mismatch state |
| App instance deleted | Best-effort client delete (D6) |

## 7. Scope: v1 and the rollout

**v1 ships Vaultwarden end to end** (in catalog, OIDC verified since
1.35.0, env-wired via #529 — zero unknowns). **ActualBudget is the
declared second** — same `kind: env` shape the moment it enters the
catalog (recipe = catalog data only). In-app apps (Forgejo, Kavita,
Memos) are v2 via `kind: in_app` — mint + checklist, no env injection —
which is when the per-app recipe list grows beyond data-only work.

## 8. Slices

Each lands green (`mix ci`), one PR per slice, umbrella issue #597
referenced without closing until the last.

- **S1 Catalog metadata** — the `OidcWiring` type + attribute + seed for
  Vaultwarden + wire exposure. Carries this plan doc onto main so later
  slices read it from their own worktrees.
  *Done when:* the attribute validates (recipe names ⊆ configurable env
  of that version), Vaultwarden's seed row carries it, the JSON API
  renders it, loader/seed tests pin it.
- **S2 Custody** — API-key intake card on the PocketID instance page +
  store op (Secret + ref) + live verification. **The audit trail is
  first-class, not an afterthought (D1 amendment):** every custody
  operation AND every use of the key (client mint, rotate, delete,
  wiring state changes) writes an audit event through the existing
  audit-event machinery, attributable in the org's audit surface —
  the platform's own record beside PocketID's.
  *Done when:* owner-paste → live-verified → stored; invalid key and
  unreachable instance render honest errors; no read-back path; every
  key use lands an audit event; tests at op and LiveView level.
- **S3 Detection + offer** — the org PocketID read, the mid-setup probe,
  the offer card states on wizard step 2, manual-input hiding.
  *Done when:* an org with ready custody sees the working offer for
  Vaultwarden; orgs without PocketID see nothing; all four card states
  test-pinned; default-off holds.
- **S4 Wiring op + API** — the operation (§4.5), the wizard's create →
  wire → deploy sequence, the JSON API action
  (`POST /instances/:id/connect-pocketid`, member-gated), failure/skip
  paths. **Explicit wake-race coverage (per the go):** a test pins the
  sleeping-PocketID path — the 503/unreachable wiring call fails soft
  (instance stays deployable, reason visible, retry offered), never
  blocks the deploy (D3).
  *Done when:* a stubbed-PocketID e2e create → wire → deploy ships the
  SSO env in the k8s Secret; wiring failure leaves a deployable
  instance with a visible retry; the wake-race test pins D3; the
  CLI/API path runs the same seam.
- **S5 Card + retrofit + rotation** — instance-page SSO card (all §6
  states), post-hoc connect with the scoped env-update + rollout
  restart primitive, rotate, disconnect, delete-time best-effort client
  cleanup.
  *Done when:* the card is truthful in every state; retrofit lands SSO
  on a running instance via one interaction; rotation is zero-downtime
  by test; disconnect restores the manual posture.
- **S6 Copy + docs** — the `/guides/sign-in-with-pocket-id` page gains
  the platform-flow section (manual path stays), catalog copy update,
  second-passkey and always-on weights kept prominent.
  *Done when:* the guide renders both paths; guide tests (the #529
  pattern) pin the section.

Order: S1 → S2 → S3 → S4 → S5 → S6; S2 and S3 are parallelizable after
S1.

## 9. Risks

- **Held key = full admin of the org's identity.** Mitigations: the
  §4.3 discipline, audit-log visibility inside PocketID, revocable by
  the owner unilaterally. Residual risk accepted only via D1.
- **Upstream API drift** on a catalog PocketID bump: the probe suite
  (§2's transcript) becomes a catalog-bump checklist item; wiring also
  feature-flagged (`FeatureFlags`, fail-closed) for instant shutdown.
- **Rollout-restart primitive touches running workloads** — scoped to
  recipe keys only, tested; a bad apply must leave the old Secret
  intact (apply-order: Secret update then rollout).
- **Wake-race UX** (first wiring attempt while PocketID wakes):
  visible retry, never silent; the copy points at always-on.
- **Vaultwarden SSO_* contract drift upstream**: recipe is
  per-AppVersion; a bump that renames env fails catalog validation
  loudly (S1), not at deploy time.
- **Orphaned PocketID clients** if best-effort delete fails: harmless,
  visible in PocketID admin, named `FluxVale · …` — documented.

## 10. Terence's decisions — settled Nov 8 2026

All accepted as recommended:

- **D1 Custody model — owner-pasted admin API key stored cluster-side**
  (§4.3), with the amendment that the **audit trail is first-class in
  S2**: every custody operation and every key use writes a
  platform-side audit event (see §8 S2).
- **D2 Offer placement — both**: wizard config step + instance-page card.
- **D3 Failure posture — IdP problems never block app deploys**;
  degrade + visible retry.
- **D4 v1 app set — Vaultwarden only**; more apps join by adding
  `oidc_wiring` recipes to their catalog entries (standing
  catalog-evaluation policy).
- **D5 The env-update + rollout-restart primitive — SSO-scoped now**,
  general env editing stays deferred.
- **D6 Client cleanup on app-instance delete — best-effort automatic.**
- **D7 Offer default — opt-in toggle, checkbox unticked.**
- **D8 Allowed users on minted clients — all users now**, group
  curation later.
