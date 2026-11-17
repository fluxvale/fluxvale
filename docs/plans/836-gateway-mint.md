# Plan: Gateway enrollment with one Tailscale credential — the platform mints (#836)

Status: **PLAN — awaiting the owner's go** (relayed by the PA; implementation
fans out only on the relay). Design is ruled, not open:
[ADR-0040](../adr/00040-strong-private-access-and-custom-domains.md)
Amendment 3. This plan is slices, sequencing, and edge cases only.

Umbrella: #836. Plan-first per the standing gate.

## The shape in one paragraph

A user pastes **one** credential — the Tailscale API token, now with the
`auth_keys` scope — and the platform mints its own join keys from it
whenever a gateway enrolls or re-enrolls. `auth_key` becomes optional
end to end: present = the documented two-paste fallback for
scope-minimalists, absent = mint. The minted key is tagged
(`tag:fluxvale-gateway`), single-use, non-ephemeral, pre-authorized,
short-TTL (1h default), lives only in the credential Secret, and is
revoked explicitly on every failure/exit path (consumption already
auto-revokes one-off keys server-side). The Terraform provider drops its
`auth_key` requirement, the owner stack drops the `tailscale_auth_key`
variable, and the public docs tell the one-paste story with the scope
tradeoff named.

## Scope fence

- **No OAuth client work** (ADR-0040 §5: API key first; OAuth is the
  self-serve upgrade, its own lane).
- **No auto-re-mint in the observer.** Deployment readiness cannot
  distinguish "bad key" from "crashloop"; a tick that mints on
  not-ready mints unboundedly. Repair stays owner-triggered — it just
  stops asking for a paste (ruled below, R1).
- **No migration.** `auth_key` is an argument, not a column; nothing
  moves in Postgres.
- **No CLI/MCP delta.** The CLI has no gateway-enable verb (verified:
  `apps/cli` exposes only status/attach/detach/resume); MCP likewise.
- **No pricing, policy, or billing change.** The funded/paid gates,
  scopes table, and settle discipline are untouched.

## Verified ground truth (read, not assumed)

**The ruling** — [ADR-0040](../adr/00040-strong-private-access-and-custom-domains.md)
Am. 3 (lines 697–736): four-scope token (`dns` + `devices:routes` +
`devices:core:read` + `auth_keys`); mint a **tagged, short-lived,
single-use** key per enrollment; drift/repair re-mints; the two-paste
flow stays as the fallback; §12's trust table is already enlarged —
do not re-litigate.

**The platform today:**

- `access_gateway.ex`: `argument(:auth_key, …, allow_nil?: false)` on
  both `create` (line 580) and `update_credential` (line 637);
  `set_api_token` (#760) is update-only and owner-only — a gateway row
  must exist before any token intake, which is why create gains the
  token argument (R2).
- `ProvisionCluster` runs cluster work in `after_action` inside the
  create transaction; a failed create rolls the row back and
  `cleanup_failed_provision` deletes both Secrets (the api-credential
  one already rides that list — mint revocation slots in beside it).
- `Tailscale` provider: `write_credential` writes only `TS_AUTHKEY`;
  the pod runs `containerboot` with `TS_AUTH_ONCE=true` and node state
  on a PVC, so **restarts with retained state never touch the key** —
  the key is consumed only when the node logs in fresh (first join, or
  lost PVC). `read_credential` exists for the `:provision` trigger's
  retry. `update_credential` restarts the pod (or re-applies objects
  for `:provisioning` rows; writes-only for `:suspended`).
- `ApiClient` (`access_providers/tailscale/api_client.ex`): pure Req,
  bearer header only, 401→`:unauthorized` / 403→`:forbidden` already
  split, error bodies snippet-truncated, success bodies never logged.
- Tests: gateway lifecycle in
  `access_gateway/changes_test.exs` (Mimic-stubs the provider module),
  provider internals in `access_providers/tailscale_test.exs`
  (Mimic-stubs the K8s resource modules), wire contract in
  `access_providers/tailscale/api_client_test.exs` (Mimic-stubs `Req`).
- Panel (`flux_vale_web/live/org_live/access.ex`): enable form
  (`#access-enable-form`, auth key required), token form
  (`#access-api-token-form`), re-paste panel (`#access-repaste-form`,
  auth key required). Secrets are stripped from re-renders
  (`clear_key_display`).

**The provider repo** (`terraform-provider-fluxvale`, origin/main =
v0.5.0): `auth_key` is Optional+Sensitive+RequiresReplace with a
create-time "auth_key is required to enable a gateway" error;
`api_token` is true WriteOnly with `rotate_api_token_on`, sent once on
create **after** the gateway reaches active (the claim sweep needs a
node). `adoptExistingGateway` recovers the singleton-conflict POST.
Acceptance is env-gated (`TF_ACC`, `TF_ACC_TAILNET_DOMAIN` +
`TF_ACC_TAILSCALE_AUTH_KEY`); the owner stack
(`examples/owner-stack`) carries the `tailscale_auth_key` variable
(tfvars row, README pairing table + "set BEFORE the first apply"
caveat) and wires `auth_key = var.tailscale_auth_key`.

**Upstream mechanics** (verified against Tailscale's API reference —
the repo's own `api.md` at commit `4e822c0`, and kb/1085, validated
Nov 2026):

- `POST /api/v2/tailnet/-/keys` with
  `{"capabilities":{"devices":{"create":{"reusable":…,"ephemeral":…,"preauthorized":…,"tags":["tag:…"]}}},"expirySeconds":…,"description":"…"}`.
  Response returns `id` and `key` (`tskey-auth-<keyid>-…`) **once**;
  the key id is embedded in the key value itself. `expirySeconds`
  defaults to 90 days when omitted. `description` ≤50 chars
  (alphanumerics, hyphens, spaces).
- With a **user-owned API access token** (our shape), tags on a minted
  key are optional-but-allowed; the tag must be owned in the tailnet's
  `tagOwners` or the join fails. "Exactly one capability scope" —
  `devices.create` only.
- **One-off (non-reusable) keys are revoked automatically by Tailscale
  the moment they are used** (kb/1085: "Tailscale automatically
  revokes one-off keys after they are used"). Consumption is
  revocation; there is no still-valid window after a successful join.
- `DELETE /api/v2/tailnet/-/keys/{keyid}` revokes explicitly (200;
  deleting an already-invalid key is not an error to tolerate — treat
  non-2xx as "stands down, TTL bounds it", never as a teardown
  blocker).
- The `auth_keys` scope is what authorizes key create/delete for
  user-owned tokens (docs: "To create new auth keys … use the
  `auth_keys` scope"; kb/1623's old→new scope table). A token without
  it authenticates fine and fails the mint with 403.
- Tagged devices have key expiry disabled by default (kb/1085) — the
  joined gateway node does not silently expire at 180 days.

## Design rulings (the seven questions)

### R1 — The mint flow

**When the platform mints:**

| Event | Mints? | Why |
| --- | --- | --- |
| `create` with no `auth_key` | **yes** | The one-paste enable. |
| `update_credential` (reconnect) with no `auth_key` | **yes** | Am. 3's "drift/repair re-mints instead of asking for a re-paste". One click, zero pastes. |
| Pod restart, state PVC intact | no | `TS_AUTH_ONCE` + persisted state: the node rejoins as itself; the key is never read. |
| Pod restart, PVC lost / node deleted | via reconnect | Lands `:needs_attention` (existing observe copy); the owner's reconnect click mints fresh. No auto-mint — see the scope fence. |
| `:provision` trigger (object drift repair) | no | SSA re-apply can't deliver a new key without a restart; re-minting there would restart pods on every drift tick. The stored credential is re-read as today. |
| `set_api_token` | no | Token intake, not an enrollment. |

**Key shape** (pinned; every field config-overridable where it has an
ops reason to move):

- `reusable: false` — single-use; the join consumes and thereby
  revokes it (the auto-revoke fact above).
- `ephemeral: false` — the gateway is a persistent node on a PVC
  (ADR-0039 §1; an ephemeral key would make the node vanish on any
  offline blip).
- `preauthorized: true` — the node must not sit in device-approval
  limbo; nobody is watching the console.
- `tags: ["tag:fluxvale-gateway"]` — Am. 3's config-pinned tag
  (`config :flux_vale, :tailscale_api`, `enrollment_tag`). A minted key
  can only ever join a node carrying this tag; `tagOwners` must own it
  — the onboarding copy states this (the API may accept the mint and
  fail the join when the tag is unowned; that surfaces as
  never-ready → `:needs_attention`, honest).
- `expirySeconds: 3600` (config `enrollment_ttl_seconds`) —
  "minutes-to-hours" per Am. 3; one hour is generous for a join that
  happens within one rollout.
- `description: "fluxvale gateway <hostname>"` — ≤50 chars, carries no
  org or app names (the §1 opacity rule).

**Revocation after successful enroll:** consumption IS revocation for
one-off keys — Tailscale invalidates them on use, so a post-active
DELETE limb would revoke an already-dead key once per enrollment.
Ruled out. **Explicit `DELETE` runs on the three paths where a minted
key can be left unconsumed**: a failed create's rollback
(`cleanup_failed_provision`), teardown (`teardown_gateway`), and
re-mint supersede (reconnect revokes the prior minted key before
writing the new one). Best-effort on all three: the original error or
the teardown wins; the 1h TTL bounds a missed revoke.

### R2 — `auth_key` optional end to end

- **Create**: `auth_key` becomes `allow_nil?: true`; a new sensitive,
  write-only `api_token` argument rides the same POST (owner-fenced —
  see below). Exactly one of the two: both absent → InvalidArgument
  "paste an auth key or an API token"; both present → InvalidArgument
  "paste one or the other" (refusing ambiguity is cheaper and more
  honest than a silent precedence rule).
- **The token at create is owner-only**, matching #760's ruling that
  the token is the owner's to paste: the create policy stays
  member+funded+paid; the change re-fences org-owner when
  `api_token` is present (the `SetApiToken.ensure_org_owner`
  precedent). A member enabling with their own pasted auth key is
  unchanged.
- **Create-time token store does NOT run the claim sweep** — the node
  does not exist yet. Claims converge through a new observer limb:
  when the row is `:active` with a token stored, the observe pass runs
  the shared `ClaimUnclaimedDomains` (idempotent — claimed domains are
  skipped by row, so steady-state cost is nil). This closes the gap
  the #837 review caught: a domain verified **before** the gateway
  existed has no later verify event to sweep it, and today's guarantee
  is "token save claims all verified domains" — the create-time store
  must keep it. The provider therefore stops needing its separate
  after-active token PATCH on the mint path.
- **`update_credential`**: `auth_key` becomes optional. Absent +
  stored token → mint. Absent + no token → InvalidArgument "paste an
  auth key, or save an API token in Settings first". A pasted key
  keeps today's semantics verbatim (including the suspended
  write-only arm — the user's key, their TTL). **Mint on a
  `:suspended` row is refused** ("resume first, then reconnect"): a
  minted 1h key would sit unconsumed until a resume that may be days
  out, and land expired.
- **Failure modes surface honestly** (the `ApiClient` taxonomy already
  splits them; the mint adds its own copy, never reusing the
  claim-drift sentences):

  | Mint failure | Copy (field error on the action) |
  | --- | --- |
  | no stored token | "No API token is saved for this gateway. Paste an auth key, or save the token in Settings → Access" |
  | `:unauthorized` (401) | "Your Tailscale API key was rejected. Paste a fresh one in Settings → Access" |
  | `:forbidden` (403) | "Your Tailscale API key can't create join keys — add the `auth_keys` scope when you mint it, or paste an auth key instead" |
  | other (`api_error`/`:network_error`/`:bad_payload`) | "Couldn't reach Tailscale to create a join key. Try again" |

  The 403 sentence is the actionable one the issue demands: it names
  the missing scope and both exits.

### R3 — Where the minted key lives

- **Value**: process memory → the credential Secret's `TS_AUTHKEY` →
  consumed by the pod at join. Never an attribute, never Postgres,
  never a function return above the provider seam, never a log line
  (the ApiClient logs only non-2xx body snippets; Tailscale error
  bodies do not echo keys — the create response, which does contain
  the key, is never logged).
- **Minted-vs-pasted marker**: the credential Secret gains
  `FV_MINTED => "1"` beside `TS_AUTHKEY`. The marker is what gates
  revocation — **a user-pasted key is never revoked by us** (it may be
  their reusable key for other devices). The key id for `DELETE` is
  parsed from the `tskey-auth-<keyid>-…` value's own prefix (the API
  embeds it), so no second store can drift.
- **Audit**: Am. 3's "every mint is audit-logged" is met by the action's
  existing PaperTrail record (actor + action name — the mint rides
  `create`/`update_credential`) plus one `Logger.info("gateway <id>
  minted enrollment key <keyid>")` line. Ids only, never values.
- **Terraform state/plans**: nothing new. The platform mints
  server-side; the wire stays write-only for both credentials; the
  provider's state carries no key material it doesn't already.

### R4 — Provider changes + version

- `Create` drops the hard `auth_key` error; the refusal moves to
  neither-credential: "set `api_token` (the platform mints the join
  key) or `auth_key` (the legacy path)". With `api_token` and no
  `auth_key`, the token rides the POST and the separate after-active
  `SetGatewayApiToken` call is skipped (the platform stored it at
  create; claims converge via the observer). `auth_key` + `api_token`
  both set keeps today's POST-then-PATCH flow.
- `ModifyPlan`/schema: `auth_key` keeps RequiresReplace + the
  replacement rejection (removing it from config still plans a
  replacement, still rejected — unchanged semantics, no compat
  break). `docs/resources/access_gateway.md` and the compatibility
  note gain the mint wording.
- `adoptExistingGateway`'s warning copy drops the "auth_key cannot be
  verified" clause when no key was sent — the platform holds the
  enrollment credential.
- Version **v0.6.0** (`version.go` + install-guide archive sweep +
  the monorepo `docs/public/automation/terraform.md` version pins),
  per the repo's release rules.

### R5 — Owner-stack README delta

Drop the second credential entirely: delete `tailscale_auth_key`
(variable, tfvars row, README pairing-table row, the "set BEFORE the
first apply" caveat — the apply no longer half-lands without it) and
add `tailscale_api_token` → `api_token` on the gateway (write-only,
ephemeral var, never in tfvars — the FLUXVALE_PAT pattern, not the
old tfvars one). The README's token wording gains the scope list
`dns devices:routes devices:core:read auth_keys`. The adoption
runbook line changes shape: adopting an existing gateway needs
neither credential. The acceptance workflow's Tailscale token scope
list gains `auth_keys`, and the mint acceptance class keys on
`TF_ACC_TAILSCALE_API_TOKEN` (the legacy
`TF_ACC_TAILSCALE_AUTH_KEY` stays for the fallback class).

### R6/R7 — Tests and slices

Per slice below. House rules that bind every slice: test data through
actions, Mimic at the same seams the existing files use, 100%
coverage by exclusion-not-luck, `MIX_TEST_PARTITION=836-<slice>` for
platform lanes, conventional-commit PR titles carrying `(#836)`, PR
bodies from files, commits as `Terence Ponce <terence@fluxvale.com>`
(never `--author` or env overrides). The lane's **last** monorepo PR
(S5) opens with `Closes #836`; every other PR references it.

## Repos and worktrees

Two repos, two chains (the #731 shape):

- Monorepo: one worker, `git worktree add ../fv836-<slice> -b
  <type>/836-<slice> origin/main` from `~/Work/FluxVale/fluxvale`.
- Provider: one worker, worktrees from
  `~/Work/FluxVale/terraform-provider-fluxvale` (`../tpfv-836-<slice>`);
  the committed identity is `Terence Ponce <terence@fluxvale.com>`.

Two generated artifacts, regenerated in the same PR as any
route/action change and never hand-edited:
`apps/platform/priv/open_api.json` (`mix flux_vale.open_api`) and
`crates/fluxvale-api/src/types.rs` (`cargo xtask openapi` from
`apps/cli`; say so in the PR if the diff is empty).

## The slices

Order is the build order. S1→S2→S3 are sequential (one module stack);
S4 and P1 parallelize after S3 pins the wire; P2 follows P1; S5 last.

### S1 — platform: `ApiClient` key mint + revoke

**Repo/worktree:** monorepo, `fv836-s1`.

**What lands** — `access_providers/tailscale/api_client.ex`:

- `keys_create(token, opts)` → `POST /api/v2/tailnet/-/keys` with the
  R1 shape (`opts` carries tag/ttl/description so the config policy
  stays at the caller). Returns `{:ok, %{id: String.t(), key: String.t()}}`.
  A 2xx without both fields is `{:bad_payload, status}` (the client's
  contract-break rule — never converge on garbage). The response body
  is never logged.
- `keys_delete(token, key_id)` → `DELETE /api/v2/tailnet/-/keys/{keyid}`,
  `write_result/1` semantics (404-tolerance is the caller's policy,
  not the client's).
- The 401/403 split and the bearer-only credential discipline are
  inherited verbatim — no new error classes.

**Tests** — extend `api_client_test.exs`: request shape (capabilities,
`expirySeconds`, bearer header), both-fields response, bad-payload
refusal, 401/403 mapping for both verbs, delete's 2xx.

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=836-s1 mix test test/flux_vale/contexts/infrastructure/access_providers/tailscale/api_client_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=836-s1 mix ci
# expected: exit 0
```

PR: `feat(platform): tailscale key mint and revoke API client (#836)`.

### S2 — platform: the mint at the provider seam

**Repo/worktree:** monorepo, `fv836-s2` (after S1).

**What lands**

- `access_provider.ex`: minting and writing are **one provider
  operation** — a minted key never crosses the seam as a bare value,
  because the write-failure revoke needs the minting token and the
  fresh key id, and both live inside the provider (#837 review,
  follow-up). Two new callbacks beside
  `revoke_enrollment_credential(AccessGateway.t()) :: :ok`:
  - `provision_gateway_minted(AccessGateway.t()) ::
  {:ok, %{credential_secret_ref: String.t()}} | {:error, term()}` —
  the create-path variant of `provision_gateway/2` (same return
  contract).
  - `reconnect_minted(AccessGateway.t()) :: :ok | {:error, term()}` —
  the reconnect variant of `update_credential/2`'s state-matched
  semantics (provisioning → re-apply, active → restart).
  Provider-agnostic vocabulary only; a WireGuard impl answers
  `{:error, :unsupported}`.
- `access_providers/tailscale.ex`:
  - Both mint callbacks share one private flow:
    `read_api_credential` → `ApiClient.keys_create` (tag/ttl/
    description from `config :flux_vale, :tailscale_api` — defaults
    `enrollment_tag: "tag:fluxvale-gateway"`,
    `enrollment_ttl_seconds: 3600`) → write the credential Secret with
    the marker → then the existing provision/update limbs. Errors pass
    through untranslated (`:no_api_token`, `:unauthorized`,
    `:forbidden`, `:network_error` …) — the copy table is the change
    layer's, R2. `provision_gateway/2`'s post-credential limbs refactor
    into a shared private helper both paths call.
  - The credential Secret gains the marker: the mint path writes
    `%{"TS_AUTHKEY" => key, "FV_MINTED" => "1"}`; the paste path
    writes `TS_AUTHKEY` alone (SSA upsert replaces the map, so a
    re-paste after a mint clears the marker). **Before any credential
    replacement, a marked stored key is revoked** — the mint path
    (supersede) and the paste path (`update_credential/2` gains the
    same pre-write revoke) alike: a pasted key over an unconsumed mint
    would otherwise orphan it until TTL with no marker left to find it
    (#837 review).
  - **A mint whose Secret write fails revokes from memory**: the
    shared flow holds the token and the fresh key id at the failure
    point and calls `keys_delete` best-effort — the Secret never
    recorded the marker, so `revoke_enrollment_credential/1` alone
    cannot close this window (#837 review). Same shape on a reconnect
    whose post-supersede write fails.
  - `revoke_enrollment_credential/1`: read the credential Secret; if
    `FV_MINTED` is absent → `:ok` (nothing is ours); else parse the id
    from the value's `tskey-auth-<id>-` prefix, read the API token,
    `keys_delete`. Any failure → log-and-`:ok` (TTL bounds it; callers
    run it best-effort).
  - Wiring: `cleanup_failed_provision` and `teardown_gateway` call
    revoke **before** their Secret deletes (the token dies with the
    api-credential Secret — read it while it exists).
- `config/config.exs`: the two new keys documented beside the existing
  `:tailscale_api` block (defaults in code, config optional).

**Tests** — extend `tailscale_test.exs`: mint happy path (shape pinned
against the stubbed `keys_create`), `:no_api_token` refusal, marker
written on mint / absent on paste, a paste over a marked key revokes
it first, a mint whose Secret write fails revokes the in-memory key
id, revoke skips unmarked credentials, revoke parses the id and
tolerates API failure, cleanup/teardown call revoke before deleting
Secrets.

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=836-s2 mix test test/flux_vale/contexts/infrastructure/access_providers/tailscale_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=836-s2 mix ci
# expected: exit 0
```

PR: `feat(platform): mint single-use tagged enrollment keys at the provider seam (#836)`.

### S3 — platform: single-credential enable and reconnect

**Repo/worktree:** monorepo, `fv836-s3` (after S2).

**What lands**

- `resources/access_gateway.ex`:
  - `create`: `auth_key` → `allow_nil?: true`; new
    `argument(:api_token, :string, allow_nil?: true, sensitive?: true)`.
    New change `CreateStoresApiToken` (before `ProvisionCluster`):
    when `api_token` present — owner-fence, write the api-credential
    Secret, force `api_token_secret_ref` + `token_set_at` (the
    `SetApiToken` order: Secret first, ref second). No claim sweep
    (R2). Exactly-one-of validation lands here too (both errors as
    `InvalidArgument` on the offending field).
  - `update_credential`: `auth_key` → `allow_nil?: true`.
  - `ProvisionCluster`: when the `auth_key` argument is absent, call
    `impl_for(gateway).provision_gateway_minted/1` instead of
    `provision_gateway/2` (the create row has no credential Secret
    yet; the retry shape is unchanged — a stored credential still
    answers the trigger).
  - `RepasteCredential`: absent `auth_key` → suspended rows refuse
    (R2 copy); otherwise call `impl_for(gateway).reconnect_minted/1`
    (supersede-revoke, mint, write, restart/re-apply — one provider
    operation, S2). The domain-refresh limb is untouched.
  - `ObserveAccessGateway`: the active-with-token pass runs
    `ClaimUnclaimedDomains` (idempotent) — the R2 convergence limb.
  - The R2 copy table rendered at the change layer; a `mint_error/1`
    helper maps the provider atoms to the four sentences.
- Regenerate `open_api.json` (+ `types.rs`; note if empty).
- No scope-table change (same route, same `gateways:write`).

**Wire contract**

```
POST /api/v1/access-gateways
{"data":{"type":"access_gateway","attributes":{
  "tailnet_domain":"…", "auth_key":"tskey-auth-…" | "api_token":"tskey-api-…"}}}
```

Both credentials write-only (never echoed); response default_fields
unchanged. Failures are 400 `InvalidArgument` with the R2 sentences.

**Tests** — extend `access_gateway/changes_test.exs`: mint enable
(stubbed `provision_gateway_minted`) lands `:provisioning` with the
Secret written; exactly-one-of both directions; token-at-create by a
non-owner refused; token-at-create writes ref+stamp and skips the
sweep (the observer limb claims later); reconnect-without-key mints
(stubbed `reconnect_minted`) and lands `:provisioning`;
reconnect with no token anywhere refused; reconnect on suspended
refused; mint-failure matrix (the four sentences) fails the action
and rolls back the create; minted key never in the version record's
inputs (the sentinel check the env tests use); a pasted key keeps
every current test green unchanged.

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=836-s3 mix test test/flux_vale/contexts/infrastructure/access_gateway/changes_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=836-s3 mix ci
# expected: exit 0
mix flux_vale.open_api --check
# expected: "open_api.json up to date"
cd ../cli && cargo xtask openapi --check
# expected: "ok: types.rs matches the committed spec"
```

PR: `feat(platform): single-credential gateway enable — auth_key optional, platform mints (#836)`.

### S4 — platform: the panel's one-paste enable and paste-free reconnect

**Repo/worktree:** monorepo, `fv836-s4` (after S3).

**What lands** — `flux_vale_web/live/org_live/access.ex`:

- Enable form: the auth-key input becomes optional, an API-token
  input joins it ("paste your API token and we create the join key
  for you"), one-of validation client-visible; the copy states the
  four scopes and the `tagOwners` requirement (R1's onboarding note).
- Re-paste panel: when the gateway has a stored token
  (`api_token_set`), the button reads "Reconnect" (the mint path) and
  the key input stays hidden until the user selects "Paste an auth key
  instead" — the fallback the 403 copy names; revealing it submits the
  pasted `auth_key` (#837 review: the UI must offer the exit the error
  describes). Without a token, today's form stands.
- `clear_key_display`'s strip covers `:api_token` on the enable form
  (same no-read-back rule).

**Tests** — the access LiveView tests: one-paste enable posts
`api_token` and not `auth_key`; neither → field error; reconnect with
a token makes no key input; the token value never re-renders.

**Screenshots**: user-visible surface — before/after of the enable
card and the reconnect panel, light+dark, per the capture rules
(`apps/e2e/capture.mjs`, absolute raw URLs, `--mask` on secret
fields).

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=836-s4 mix test test/flux_vale_web/live/org_live/access_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=836-s4 mix ci
# expected: exit 0
```

PR: `feat(platform): one-paste enable and paste-free reconnect (#836)`.

### P1 — provider: enable without an auth key

**Repo/worktree:** provider, `tpfv-836-p1` (after S3's wire lands;
the fake server pins it).

**What lands** — `gateway_resource.go`:

- `Create`: replace the auth-key requirement with the
  neither-credential error (R4 copy); mint path sends `api_token` in
  the POST body and skips the after-active `SetGatewayApiToken`;
  both-set keeps the current flow; `adoptExistingGateway` warning
  updated for the no-key case.
- `internal/client/gateways.go`: `CreateGatewayInput.ApiToken`
  (omitted when empty; write-only).
- `fake_test.go` + `gateway_resource_test.go`: mint create, fallback
  create, neither-credential diagnostic, both-set behavior, adoption
  copy, state carries no key material.
- `docs/resources/access_gateway.md`: `auth_key` now "the documented
  fallback"; absence means mint; the scope list gains `auth_keys`.

**Done when**

```sh
cd ~/Work/FluxVale/tpfv-836-p1
gofmt -l . && go vet ./... && go test ./... && go build ./...
# expected: gofmt prints nothing; "ok" per package; exit 0
mise x -- tofu fmt -check -recursive examples
# expected: no output, exit 0
```

PR: `feat(provider): enable a gateway without an auth key — platform mints (#836)`.

### P2 — provider: release v0.6.0 + owner stack + acceptance

**Repo/worktree:** provider, `tpfv-836-p2` (after P1).

**What lands**

- `version.go` → `0.6.0`; `docs/guides/install.md` archive sweep.
- `examples/owner-stack/`: delete `tailscale_auth_key` (variable,
  tfvars row, README rows, the half-apply caveat), add
  `tailscale_api_token` as an ephemeral sensitive var → gateway
  `api_token` (R5; never in tfvars — env like `FLUXVALE_PAT`).
- `acceptance_test.go`: a mint class (no auth key, token only,
  asserts `active`) gated on `TF_ACC_TAILNET_DOMAIN` +
  `TF_ACC_TAILSCALE_API_TOKEN`; the legacy class keeps
  `TF_ACC_TAILSCALE_AUTH_KEY`.
- `.github/workflows/acceptance.yml` preflight: `auth_keys` joins the
  Tailscale token scope list; the new env is minted there.
- Tag `v0.6.0` on main **only after the platform mint path is live on
  production and a token-only create succeeds against it** — the
  provider's default API URL is production, so a published token-only
  create against an unminted API fails (#837 review; the release
  workflow publishes the tag).

**Done when**

```sh
cd ~/Work/FluxVale/tpfv-836-p2
gofmt -l . && go vet ./... && go test ./... && go build ./... \
  && ./scripts/test-check-tag-version.sh && shellcheck scripts/*.sh
# expected: exit 0
grep -c "auth_key" examples/owner-stack/main.tf
# expected: 0
git show v0.6.0 --stat --oneline   # after tagging
# expected: the v0.6.0 tag commit
```

PR: `chore(provider): v0.6.0 — mint-first gateway enrollment (#836)`.

### S5 — docs: the one-token story (closes the lane)

**Repo/worktree:** monorepo, `fv836-s5` (after P2 tags v0.6.0).

**What lands**

- `docs/public/guides/custom-domains.md`: the §"Where the feature is
  today" token paragraph — four scopes including `auth_keys`, the
  one-paste enable, the fallback named for scope-minimalists.
- `docs/public/automation/terraform.md`: the gateway example drops
  `auth_key`; version pins → 0.6; the write-only `api_token` note
  covers the mint.
- ADR-0040 Am. 3 annotation (one paragraph, no re-litigation): the
  implementation pins — one-off keys auto-revoke on consumption (so
  no post-active revoke limb exists), the `tagOwners` onboarding
  dependency, and the config-pinned tag/TTL.

**Done when**

```sh
cd apps/platform && mix docs.lint
# expected: "docs content ok"
cd "$(git rev-parse --show-toplevel)"
grep -q "auth_keys" docs/public/guides/custom-domains.md && echo scopes-updated
# expected: "scopes-updated"
```

PR: `docs: the one-token gateway enrollment story (#836)` — opens with
`Closes #836`.

## Build order and waves

1. **Wave 1:** `S1 → S2 → S3` (one monorepo worker — shared module
   stack).
2. **Wave 2 (parallel):** `S4` (monorepo) and `P1` (provider, against
   the S3-pinned wire via the fake server).
3. **Wave 3:** `P2` (release, owner stack, acceptance), then `S5`
   (public docs; needs the tagged version for the doc pins).

Two workers in flight at the peak, never more.

## Risks and how the plan handles them

- **The tagOwners dependency is user-side setup.** The mint succeeds
  and the join fails when `tag:fluxvale-gateway` is unowned. Mitigated
  by copy (enable form + custom-domains guide name the ACL edit), and
  the failure is the existing honest never-ready → reconnect loop.
- **`expirySeconds` semantics** are pinned by S1's wire tests against
  the documented shape; if the live API clamps or rejects 3600 (docs
  only promise "defaults to 90 days"), the config knob is the escape
  — S1's staging smoke run reports before S2 builds on it.
- **403 ≠ missing scope, always.** A 403 can also mean the token's
  account lacks tailnet power. The copy names the common fix (add
  `auth_keys`) and offers the auth-key exit — honest under both
  causes.
- **Revocation best-effort vs. the P1-1 "no dangling key" rule.** The
  revoke is tried on every exit but never blocks one; the 1h TTL is
  the backstop, stated in R1 rather than implied.
- **Provider release timing.** The v0.6.0 tag waits for the mint path
  live on production (P2's gate); the owner-stack and public docs land
  only after that (P2/S5 order), so no doc tells a story production
  refuses.

## Effort

S1 0.5d · S2 1.5d · S3 2d · S4 1d · S5 0.5d (monorepo chain);
P1 1d · P2 0.5d (provider chain). **≈7 dev-days**, roughly 1.5–2
calendar weeks with review cycles.
