# Plan: Terraform-native integrations (#731)

Status: **PLAN — awaiting Terence's go** (relayed via the PA). No
implementation before that.
Decision records: [ADR-0052](../adr/00052-instance-env-updates.md)
(T1, Proposed) and
[ADR-0053](../adr/00053-terraform-secret-env.md) (T4, Proposed).
Umbrella: #731.

## The shape in one paragraph

Terraform gets three missing verbs and one honest answer to secrets.
An instance's env vars update **in place** through one merge endpoint
(no more destroy/recreate to add an integration), a `fluxvale_instance`
data source reads an app managed in another stack, and a
`fluxvale_pocket_id_sso` resource makes the one typed per-instance
integration a first-class Terraform object. Secrets never travel as
plaintext in Terraform: the CLI encrypts a value into a marked
ciphertext that only the platform can open, and the platform decrypts
it at deploy. Platform-managed integrations keep minting and holding
their own credentials; Terraform names the relationship, never the
secret.

## Scope fence

- **No env-editing UI.** The API and provider only; the instance page
  is unchanged. (The issue's own out-of-scope line.)
- **No at-rest encryption of the platform DB or etcd.** Tracked
  separately; the secrets ADR says exactly what it does and does not
  cover.
- **No secret references** (`op://`, `sops://`, `ssm://`) and no BYOK
  or per-org key custody in this lane (ADR-0053's rejected
  alternatives, each with its revisit trigger).
- **No Terraform write-only/ephemeral `env_vars` mode** in this lane
  (ADR-0053 explains why: it cannot diff on its own and needs
  Terraform 1.11+).
- **No generic `fluxvale_instance_integration` resource** (T5 — the
  design note below says why it waits).
- **No CLI `env` verbs.** The CLI ships only `secrets encrypt` (the
  encrypted mode is unusable without it). MCP tools: none.
- **No migrations.** Every change is actions, routes, modules, docs.

## Repos, worktrees, and the two generated files

Two repos, two PR trains:

- `fluxvale/fluxvale` (this monorepo). Worker worktrees:
  `git worktree add ../fv731-<slice> -b <type>/731-<slice> origin/main`
  from `~/Work/FluxVale/fluxvale`. Every `mix test` / `mix ci` command
  carries `MIX_TEST_PARTITION=731-<slice>` (#241 — parallel lanes
  sharing `flux_vale_test` produce phantom failures).
- `fluxvale/terraform-provider-fluxvale`. One clone at
  `~/Work/FluxVale/terraform-provider-fluxvale`
  (`git clone git@github.com:fluxvale/terraform-provider-fluxvale.git`),
  then one worktree per slice:
  `git worktree add ../tpfv-731-<slice> -b <type>/731-<slice> origin/main`.
  The provider repo's committed identity is
  `Terence Ponce <terence@fluxvale.com>`; a fresh clone must carry
  that local identity (the repo's own history, not an invented one)
  before the first commit.

Two generated artifacts serialize the API-shaped monorepo slices —
**never edit them by hand** and never parallelize the slices that
touch them:

1. `apps/platform/priv/open_api.json` — regenerate with
   `mix flux_vale.open_api` after any route/action change; `mix ci`'s
   staleness test fails otherwise.
2. `crates/fluxvale-api/src/types.rs` — regenerate with
   `cargo xtask openapi` from `apps/cli`; CI diffs it against the
   spec.

The SSO routes are gated by the `pocketid_sso_wiring` feature flag
(seeded enabled; the provider docs say how to check it).

PR rules for every slice: conventional-commit title, body from a file,
no reviewers requested (the lane's review arc is the architect's),
no screenshots (no user-visible UI in this lane), and `(#731)` in the
title. Only the lane's last PR opens with `Closes #731`. Commits are
`Terence Ponce <terence@fluxvale.com>` as author and committer — never
`--author`, `GIT_AUTHOR_*`, or `GIT_COMMITTER_*`.

## The slices

Order is the build order. Monorepo API slices are sequential because
they share `instance.ex`, `scopes.ex`, and both generated artifacts.
The provider slices are a second, parallel chain against the API
shapes pinned here (the fake API is enough until staging deploys).

### T1-S1 — platform: `PATCH /api/v1/instances/:id/env` + the one Secret seam

Spec: [ADR-0052](../adr/00052-instance-env-updates.md).

**Repo/worktree:** monorepo, `fv731-t1`.

**What lands**

- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance.ex`:
  a `update :update_env` action (arguments `set`/`remove`, `accept([])`,
  `require_atomic?(false)`, `change(FluxVale.Infrastructure.Instance.UpdateEnv)`),
  a membership policy for the action, and the route
  `patch(:update_env, route: "/instances/:id/env", default_fields: @detail_fields)`.
- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance/update_env.ex`
  (new): the Ash change. `before_action` re-reads the row `FOR UPDATE`,
  runs the status guard, validates the patch, merges, force-changes
  `env_vars`, and stashes
  the apply plan in the process dictionary; `after_action` writes the
  live Secret (a failure rolls the row back); `after_transaction`
  restarts the deployment for live statuses (a failure returns the
  post-commit error, row and Secret already applied).
- `apps/platform/lib/flux_vale/contexts/infrastructure/operations/env_patch.ex`
  (new, pure): normalize/validate `set`/`remove` (key shape, string
  values, no overlap), compute the platform-owned key set, merge.
  Owned keys: the version's `oidc_wiring` keys when a wiring row exists,
  the instance's backing-service `url_env` keys, and the version's
  `instance_url_env`. An owned key in `set` refuses with the key names;
  an owned key in `remove` is skipped (no-op, logged) so a Terraform
  apply that stopped naming a platform-owned key still converges.
  `host_allowlist_env` stays user-writable; when a patch
  touches it, the deployer's append helper re-adds the platform hostname
  (extract `maybe_allowlist_entry`'s body into
  `Operations.InstanceEnvDerived.allowlist_entry/3` so both paths share
  it).
- `apps/platform/lib/flux_vale/contexts/infrastructure/operations/instance_env_secret.ex`
  (new): `ApplyPocketIdEnv` generalized and renamed. One public
  `apply_to_running/4` (set + remove + upsert + restart) for the SSO
  callers, plus `upsert/4` and `restart/2` for the in-place action.
  Order stays Secret-first, restart-second.
- The three SSO operations
  (`connect_pocket_id.ex`, `disconnect_pocket_id.ex`,
  `rotate_pocket_id_secret.ex`) and
  `apps/platform/lib/flux_vale/contexts/infrastructure.ex` switch to
  the renamed seam; `apply_pocket_id_env.ex` is deleted.
- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance/validate_env_vars.ex`
  exposes a pure `check/2` the patch path reuses (the create
  validation keeps its current behavior).
- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance.ex`:
  the system row-writer `:merge_pocket_id_env` is renamed
  `:merge_system_env` (one funnel for system env merges; action name
  is audit-visible).
- `apps/platform/lib/flux_vale/api/scopes.ex`:
  `{{"PATCH", ["instances", :_, "env"]}, "instances:write"}`.
- Regenerate `apps/platform/priv/open_api.json` and
  `crates/fluxvale-api/src/types.rs`.

**Wire contract**

```
PATCH /api/v1/instances/:id/env
{"data":{"type":"instance","id":"<id>","attributes":{
  "set":{"KEY":"value"},
  "remove":["OTHER_KEY"]}}}
```

Response: the standard instance document (`@detail_fields`); env is
never echoed. Refusals are 400 (`InvalidArgument`, the house style)
with honest messages: owned keys, overlap, invalid name/value, busy
(`deploying`/`restoring`), deleting, decrypt failure, and the
post-commit restart refusal ("the environment was saved, but the
rolling restart was refused — retry").

Status rules (ADR-0052): row-only for `pending`/`error`/`lost`;
row + Secret + restart for `running`/`starting`; row + Secret, no
restart for `stopped`/`sleeping`; refuse `deploying`/`restoring`/
`deleting`.

**Tests**

- `apps/platform/test/flux_vale/contexts/infrastructure/operations/env_patch_test.exs`
  (new): pure validation, owned keys (set refuses, remove skips),
  overlap, merge.
- `apps/platform/test/flux_vale/contexts/infrastructure/resources/instance/update_env_test.exs`
  (new): the status matrix, Secret upsert inside the transaction, a
  failed upsert rolls the row back, a refused restart leaves row +
  Secret applied and returns an error, key-name-only logging, and the
  sentinel check (a secret value never appears in the response body,
  captured logs, or the PaperTrail version's changes/inputs).
- `apps/platform/test/flux_vale_web/api/instance_env_route_test.exs`
  (new): 200 shape, 400 refusals, 403 non-member, 403 wrong scope,
  `instances:write` required.
- `apps/platform/test/flux_vale_web/api/route_inventory_test.exs` and
  `open_api_route_test.exs`: the new path.
- `apps/platform/test/flux_vale/contexts/infrastructure/operations/instance_env_secret_test.exs`
  (renamed from `apply_pocket_id_env_test.exs`): the ordering contract
  unchanged.
- Existing SSO operation tests: no behavior change expected.

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=731-t1 mix test \
  test/flux_vale/contexts/infrastructure/operations/env_patch_test.exs \
  test/flux_vale/contexts/infrastructure/resources/instance/update_env_test.exs \
  test/flux_vale/contexts/infrastructure/operations/instance_env_secret_test.exs \
  test/flux_vale_web/api/instance_env_route_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=731-t1 mix ci
# expected: exit 0
mix flux_vale.open_api --check
# expected: "open_api.json up to date"
cd ../cli && cargo xtask openapi --check
# expected: "ok: types.rs matches the committed spec"
```

PR: `feat(platform): in-place instance env updates — merge API + the one Secret seam (#731)`.

### T1-S2 — provider: `env_vars` updates in place

**Repo/worktree:** provider, `tpfv-731-t1`.

**What lands**

- `internal/provider/instance_resource.go`: drop
  `mapplanmodifier.RequiresReplace()` from `env_vars`; in `Update`,
  compute `set` = keys added/changed vs `State`, `remove` = keys in
  `State` absent from `Plan`; call the new client method; apply the
  env update **after** the resize/run-state steps and before
  always-on/exposure. A null plan means "no user env": remove every
  key this resource previously managed. Platform-owned keys are never
  in the provider's state, so Terraform never tries to remove them.
- `internal/client/instances.go`: `UpdateInstanceEnv(ctx, id, set,
  remove)` PATCHing `/api/v1/instances/:id/env`; the response is the
  standard instance document.
- `internal/provider/fake_test.go`: the new PATCH route (records the
  body).
- `internal/provider/instance_resource_test.go`,
  `instance_crud_test.go`: the diff shape (set/remove), no POST/DELETE
  on an env-only change, state carries the new map, the server's 400
  surfaces verbatim, and a changed plan with a null map sends removes.
- `internal/provider/acceptance_test.go`: a nightly class that creates
  an instance, changes one var, adds one, removes one, and asserts the
  instance id never changes.
- `docs/resources/instance.md`: "updates in place" replaces "changing
  it replaces the instance"; the reserved `enc:v1:` prefix (the T4
  link); a null/omitted map clears the managed keys; import leaves
  `env_vars` null.

**Done when**

```sh
cd ~/Work/FluxVale/tpfv-731-t1
gofmt -l . && go vet ./... && go test ./... && go build ./...
# expected: gofmt prints nothing; "ok" per package; exit 0
TFPROVIDER_E2E=1 mise x -- go test ./internal/provider -run TestRealTofuSmoke -count=1 -v
# expected: "--- PASS: TestRealTofuSmoke"
mise x -- tofu fmt -check -recursive examples
# expected: no output, exit 0
```

PR: `feat(provider): update env_vars in place (#731)`.

### T2-S1 — platform: instance by slug

**Repo/worktree:** monorepo, `fv731-t2` (after T1-S1).

**What lands**

- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance.ex`:
  `read :get_by_slug` (`get?(true)`, `argument(:slug, :string)`,
  `filter(expr(slug == ^arg(:slug)))`) and
  `get(:get_by_slug, route: "/instances/by-slug/:slug", default_fields: @detail_fields)`.
- `apps/platform/lib/flux_vale/api/scopes.ex`:
  `{{"GET", ["instances", "by-slug", :_]}, "instances:read"}`.
- Regenerate `apps/platform/priv/open_api.json` +
  `crates/fluxvale-api/src/types.rs`.
- `apps/platform/test/flux_vale_web/api/route_inventory_test.exs` /
  `open_api_route_test.exs` and
  `apps/platform/test/flux_vale_web/api/instance_slug_route_test.exs`
  (new): 200 by slug, 404 unknown, 403 non-member, `instances:read`
  required.

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=731-t2 mix test test/flux_vale_web/api/instance_slug_route_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=731-t2 mix ci
# expected: exit 0
mix flux_vale.open_api --check
# expected: "open_api.json up to date"
cd ../cli && cargo xtask openapi --check
# expected: "ok: types.rs matches the committed spec"
```

PR: `feat(platform): read an instance by slug (#731)`.

### T2-S2 — provider: `data "fluxvale_instance"`

**Repo/worktree:** provider, `tpfv-731-t2` (after T1-S2).

**What lands**

- `internal/provider/instance_data_source.go` (new): `id` and `slug`
  optional with exactly-one validation in `Read` (no new dependency);
  computed `name`, `slug`, `namespace`, `status`, `exposure`,
  `always_on`, `image`, `port`, `deployed_at`, `organization_id`,
  `app_version_id`.
- `internal/client/instances.go`: `GetInstanceBySlug` on
  `/api/v1/instances/by-slug/:slug?fields[instance]=…`.
- `internal/provider/provider.go`: register the data source.
- `internal/provider/data_sources_test.go` + `fake_test.go`: both
  lookups, exactly-one refusal, 404 diagnostic.
- `docs/data-sources/instance.md` (new) and the provider's
  `README`/compat contract entry.

**Done when**

```sh
cd ~/Work/FluxVale/tpfv-731-t2
gofmt -l . && go vet ./... && go test ./... && go build ./...
# expected: gofmt prints nothing; "ok" per package; exit 0
TFPROVIDER_E2E=1 mise x -- go test ./internal/provider -run TestRealTofuSmoke -count=1 -v
# expected: "--- PASS: TestRealTofuSmoke"
```

PR: `feat(provider): fluxvale_instance data source (#731)`.

### T3-S1 — platform: SSO disconnect / rotate / wiring read (and connect dispatch)

**Repo/worktree:** monorepo, `fv731-t3` (after T2-S1).

**What lands**

- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance.ex`:
  three actions — `disconnect_pocketid` (`:map` result
  `%{instance_id, client_deleted}`, idempotent: no wiring = 200 with
  `client_deleted: false`), `rotate_pocketid_secret` (`:struct` result,
  the wiring row), and a `wire_pocket_id/3` dispatch used by the
  existing `connect_pocketid` action (pre-deploy statuses call
  `ConnectPocketId.call/3`, deployed statuses call
  `ConnectPocketId.retrofit/3`). Both new routes:
  `route(:post, "instances/:id/disconnect-pocketid", …)` and
  `route(:post, "instances/:id/rotate-pocketid-secret", …)`.
- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/pocket_id_wiring.ex`:
  `json_api` routes —
  `get(:get_by_instance, route: "/instances/:instance_id/pocket-id-wiring", default_fields: [:instance_id, :pocket_id_instance_id, :pocket_id_client_id, :pocket_id_secret_id, :wired_at])`.
- `apps/platform/lib/flux_vale/contexts/infrastructure.ex`: the domain
  delegate for the dispatch (keep the two existing ops as the seams).
- `apps/platform/lib/flux_vale/api/scopes.ex`: three routes,
  `instances:write` (POSTs) and `instances:read` (GET).
- Policies mirror `connect_pocketid` (`authorize_if(actor_present())`,
  ownership via the authorized get inside).
- Regenerate `open_api.json` + `types.rs`.
- Tests: `apps/platform/test/flux_vale_web/api/pocket_id_sso_routes_test.exs`
  (connect on pending and running, disconnect twice, rotate, read
  wired/unwired, 403/scope, flag-off), plus the inventory/openapi
  lists.

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=731-t3 mix test test/flux_vale_web/api/pocket_id_sso_routes_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=731-t3 mix ci
# expected: exit 0
mix flux_vale.open_api --check
# expected: "open_api.json up to date"
cd ../cli && cargo xtask openapi --check
# expected: "ok: types.rs matches the committed spec"
```

PR: `feat(platform): SSO wiring routes — disconnect, rotate, read (#731)`.

### T3-S2 — provider: `fluxvale_pocket_id_sso`

**Repo/worktree:** provider, `tpfv-731-t3` (after T2-S2).

**What lands**

- `internal/provider/pocket_id_sso_resource.go` (new):
  `instance_id` (Required, RequiresReplace), `pocket_id_instance_id`
  (Required, RequiresReplace), computed `pocket_id_client_id`,
  `pocket_id_secret_id`, `wired_at`; optional `rotate_secret_on`
  (any change → `Update` calls rotate; **not** a replace — a replace
  would disconnect and mint a new client, losing the client id).
  `id` is the instance id (one wiring per instance).
- `internal/client/pocket_id_sso.go` (new): `ConnectPocketId`,
  `GetPocketIdWiring`, `DisconnectPocketId`, `RotatePocketIdSecret`;
  the POSTs return the flat generic-action body, the GET returns the
  JSON:API document.
- `internal/provider/provider.go`: register the resource.
- `internal/provider/pocket_id_sso_resource_test.go` + `fake_test.go`:
  create/read/delete/rotate, a 400 busy answer surfaces, a missing
  wiring removes state, delete is idempotent (404 and no-wiring both
  succeed), and re-wiring attributes force replacement.
- `internal/provider/acceptance_test.go`: a class that skips unless
  `TF_ACC_POCKET_ID_INSTANCE_ID` is set (the gateway/domain skip
  pattern).
- `docs/resources/pocket_id_sso.md` (new).

**Done when**

```sh
cd ~/Work/FluxVale/tpfv-731-t3
gofmt -l . && go vet ./... && go test ./... && go build ./...
# expected: gofmt prints nothing; "ok" per package; exit 0
TFPROVIDER_E2E=1 mise x -- go test ./internal/provider -run TestRealTofuSmoke -count=1 -v
# expected: "--- PASS: TestRealTofuSmoke"
```

PR: `feat(provider): fluxvale_pocket_id_sso resource (#731)`.

### T4-S1 — the secrets ADR (this gate)

The deliverable is
[ADR-0053](../adr/00053-terraform-secret-env.md): the model, the
threat-surface table, key management and rotation, failure modes,
what an attacker with the ciphertext can do, and the rejected
alternatives. **No code ships until Terence approves the model.**

**Done when**

```sh
test -f docs/adr/00053-terraform-secret-env.md \
  && grep -q 'One platform keypair' docs/adr/00053-terraform-secret-env.md \
  && echo 'secrets ADR draft present'
# expected: "secrets ADR draft present"
```

### T4-S2 — platform: open `enc:v1:` values at deploy and in-place

Gate: T4-S1 approved.

**Repo/worktree:** monorepo, `fv731-t4` (after T3-S1).

**What lands**

- `apps/platform/lib/flux_vale/secrets.ex` (new): the marker parser
  (`enc:v1:<kid>:<payload>`, `enc:v1:raw:<b64>` escape), X25519 +
  HKDF-SHA256 + AES-256-GCM open, `resolve_env/2` (map + org id),
  `public_key/0`, `active_kid/0`.
- `apps/platform/lib/flux_vale/secrets/key_ring.ex` (new): parse the
  `FLUXVALE_SECRET_KEY_RING` config (list of `%{kid, private, public}`,
  `:secret_key_ring` in app env); a dev/test default key; a malformed
  ring refuses at boot, an unset ring logs loudly and leaves the
  feature unavailable.
- `apps/platform/config/runtime.exs`: read the ring (the
  `INSTANCES_BASE_DOMAIN` pattern).
- `apps/platform/lib/flux_vale/contexts/infrastructure/operations/deploy_instance.ex`:
  decrypt the composed env before the Secret write; a failure is a
  deploy `:error` naming the key and kid (never the value/ciphertext).
- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance/update_env.ex`
  (T1): decrypt only the `set` values before the Secret upsert; a
  decrypt failure refuses before the row write.
- `apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance/validate_env_vars.ex`:
  `enc:` values are valid only for
  `secret: true` schema fields or unknown keys; a marker on a
  non-secret typed field refuses.
- `apps/platform/lib/flux_vale/contexts/accounts/resources/organization.ex`:
  a `get` route `GET /api/v1/organizations/:organization_id/secret-key`
  returning `%{organization_id, kid, public_key}` (membership-fenced,
  scopeless `:any` — a public key).
- `apps/platform/lib/mix/tasks/flux_vale.secrets.new_key.ex` (new): an
  operator task that prints one ring entry (kid + base64 keys) for
  1Password.
- `apps/platform/lib/flux_vale/api/scopes.ex`,
  `apps/platform/priv/open_api.json`, and
  `crates/fluxvale-api/src/types.rs` regenerated.
- Tests: round trip, AAD org/key mismatch, unknown kid, tampered
  payload, the raw escape, deploy decrypt + failure, update decrypt +
  failure, schema rule, route, ring parsing, and the shared vector
  (T4-S3's fixture) opened here.

**Done when**

```sh
cd apps/platform
MIX_TEST_PARTITION=731-t4 mix test test/flux_vale/secrets_test.exs \
  test/flux_vale/secrets/key_ring_test.exs \
  test/flux_vale_web/api/organization_secret_key_route_test.exs
# expected: "0 failures"
MIX_TEST_PARTITION=731-t4 mix ci
# expected: exit 0
mix flux_vale.open_api --check
# expected: "open_api.json up to date"
cd ../cli && cargo xtask openapi --check
# expected: "ok: types.rs matches the committed spec"
```

PR: `feat(platform): encrypted env values — open at deploy (#731)`.

### T4-S3 — CLI: `fluxvale secrets encrypt`

Gate: T4-S1 approved. Depends on T4-S2's route.

**Repo/worktree:** monorepo, `fv731-t4-cli` (after T4-S2).

**What lands**

- `apps/cli/fluxvale-cli/src/cli.rs`: `fluxvale secrets encrypt
  --org <id|slug> --key <ENV_NAME>` — plaintext from stdin or
  `--from-file`, never from an argument; refuses a TTY with the pipe
  example; prints only the marker.
- `apps/cli/fluxvale-cli/src/writes.rs` (or a new `secrets.rs`): the
  command; resolve the org id by matching `--org` against
  `GET /organizations` id/slug; fetch the public key; validate the env
  name; encrypt.
- `apps/cli/fluxvale-cli/src/crypto.rs` (new): X25519 ephemeral +
  HKDF-SHA256 + AES-256-GCM, the same AAD
  (`org_id || 0x00 || env_key`), the raw escape, and a
  test-injectable ephemeral key/nonce.
- `crates/fluxvale-api`: the public-key call + types.
- `apps/cli/xtask` regenerated `types.rs` (from T4-S2's spec).
- The shared vector: `apps/platform/test/support/fixtures/secret_env_vector.json`
  (keypair, kid, org, key name, plaintext, nonce, ephemeral key,
  marker), `include_str!`-ed by the CLI test, read by the platform
  test. Both sides encrypt **and** decrypt the vector.
- `apps/cli/fluxvale-cli/Cargo.toml`: `x25519-dalek`, `hkdf`, `sha2`,
  `aes-gcm`, `base64`, `getrandom` (licenses within `deny.toml`).
- `docs/public/automation/cli.md` "Secrets" section + the provider
  page reference.

**Done when**

```sh
cd apps/cli
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
# expected: exit 0; "test result: ok"
cargo xtask openapi --check
# expected: "ok: types.rs matches the committed spec"
printf '%s' 'vector-plaintext' | cargo run -q -p fluxvale-cli -- secrets encrypt \
  --org test-org --key API_KEY
# expected: one line starting "enc:v1:" (the fixture's marker when the
# fixed ephemeral key/nonce are used by the test hook; the command
# itself is random)
```

PR: `feat(cli): fluxvale secrets encrypt (#731)`.

### T5 — generic integration resource: design note, no build

**Verdict: do not build now.** The platform's integration model is
recipe-based and typed: `oidc_wiring` and `backing_service` are
declared on the app version, injected by the platform, and only SSO
has a per-instance choice. A generic
`fluxvale_instance_integration { type, target }` would need a
server-side type registry with per-type connect/disconnect/read
actions and a per-type status shape — and today it would have exactly
one type, `pocket_id_sso`, which T3 already models honestly as a
typed resource. The generic env-var-shaped app-to-app case is served
better by T1 + T2 + T4: Terraform passes a URL or an encrypted
credential, and the platform holds the secret.

Revisit trigger: **a second typed per-instance integration exists**
(a shared queue/cache, an SMTP relay, a platform-minted webhook
secret). At that point the registry shape is a real design, not a
facade over one type. Until then, typed resources win on
documentation, compile-time validation, and reviewability.

**Done when**

```sh
grep -q 'Verdict: do not build now' docs/plans/731-terraform-integrations.md \
  && echo 'T5 verdict recorded'
# expected: "T5 verdict recorded"
```

### R1 — provider release + public docs

After T1-S2, T2-S2, T3-S2 (and T4-S3 if approved) are on the
provider's `main`:

- Provider `chore(provider): v0.3.0` PR: `internal/provider/version.go`,
  `docs/guides/install.md` archive names, the compatibility note
  ("`env_vars` updates in place from 0.3.0; it is write-only on the
  wire — never echoed — but a normal Terraform attribute, not a
  Terraform 1.11 write-only attribute; encrypted values work on every
  version").
- Tag `v0.3.0` on `main` (the release workflow publishes the signed
  assets).
- Monorepo `docs(public): terraform-native integrations (#731)`
  PR: `docs/public/automation/terraform.md` (resource list, in-place
  env, the instance data source, the SSO resource, the encrypted
  values flow, `~> 0.3`, the compatibility note) and
  `docs/public/automation/cli.md` (the encrypt command). The last PR
  merged in the lane opens with `Closes #731` (R1 when T4 is not
  built, T4-S3 when it is); every other PR references the issue.

**Done when**

```sh
cd apps/platform && mix docs.lint
# expected: "docs content ok"
git -C ~/Work/FluxVale/terraform-provider-fluxvale fetch --tags \
  && git -C ~/Work/FluxVale/terraform-provider-fluxvale show v0.3.0 --stat --oneline
# expected: the v0.3.0 tag commit
```

## Build order and waves

1. **Wave 1 — parallel:** `T1-S1` (monorepo) and `T1-S2` (provider,
   against the pinned API shape).
2. **Wave 1 continues:** `T2-S1` → `T3-S1` in the monorepo chain;
   `T2-S2` → `T3-S2` in the provider chain.
3. **Wave 2:** `T4-S2` → `T4-S3` (only with the T4 go).
4. **Wave 3:** `R1` (release + docs).

The monorepo chain is one worker (shared files + generated artifacts);
the provider chain is one worker. Two workers in flight, not eight.

## Risks and how the plan handles them

- **The provider repo is a fresh clone.** Setup, identity, and
  `mise install` are stated in T1-S2; the first worker reports any
  friction instead of inventing a fix.
- **Generated-file collisions.** The API slices are sequential; both
  artifacts are regenerated in the same PR as the route change.
- **100% coverage.** The K8s-failure and status branches are the test
  cost; use the documented coveralls exclusions only for the
  DB-outage/race classes (#86), never for a reachable branch.
- **The post-commit restart error** is the one Ash subtlety: a test
  pins "row + Secret applied, response is an error". If the hook does
  not surface it, the worker reports before choosing a fallback.
- **Acceptance is nightly-only.** Provider feature PRs are proven by
  the fake-server tests and a compiled acceptance class; the staging
  acceptance run is post-merge verification and is reported as
  unverified until it runs.
- **The SSO flag.** Staging/prod must have `pocketid_sso_wiring` on
  for the acceptance class; the docs say so.
- **Cross-language crypto.** One shared vector, tested on both sides;
  a mismatch fails one suite, not a deploy.

## Effort

- T1-S1 3d · T2-S1 0.5d · T3-S1 2d (monorepo chain, sequential).
- T1-S2 1.5d · T2-S2 1d · T3-S2 1.5d (provider chain, parallel).
- T4-S2 2.5d · T4-S3 1.5d (only with the T4 go).
- R1 1d.

Critical path: **≈6.5 dev-days to T1–T3 merged + released, ≈10.5
with T4**, so roughly **1.5–2.5 calendar weeks** with review cycles.

## Decisions for Terence

1. **T1 semantics** — in-place merge, row-is-truth, explicit removes,
   platform-owned keys refused, restart-after-commit with an honest
   partial-failure answer ([ADR-0052](../adr/00052-instance-env-updates.md)).
2. **T4 model** — encrypted values (one platform key, ciphertext bound
   to org + variable, `fluxvale secrets encrypt`) instead of write-only
   inputs or secret references
   ([ADR-0053](../adr/00053-terraform-secret-env.md)); and whether the
   go includes building it now or only the design.
3. **T5** — not now; typed resources until a second integration type
   exists.
