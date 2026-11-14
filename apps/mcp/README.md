# fluxvale-mcp

The FluxVale MCP server: FluxVale as tools for AI agents. Slices W2a
+ W2b of [#484](https://github.com/fluxvale/fluxvale/issues/484) —
the server core (rmcp streamable HTTP over the shared `/api/v1`
client crate `crates/fluxvale-api`, personal access token passthrough,
the read tools) plus the write surface: deploy through destroy,
resize, the access gateway, custom domains, and Pocket ID sign-in
wiring, with the destructive pair elicitation-gated. W3a ships the
container image, CI publish, and the k3d exposure
([running in k3d](#running-in-k3d)).

## The tools (W2a + W2b)

| Tool | Scope | Answers |
| --- | --- | --- |
| `whoami` | any | The identity the token carries — user id, email, platform role, username, organizations (id/slug/name). |
| `onboarding_status` | `wallet:read` (+ `instances:read` for the count) | Account verified, organizations, the chosen org's wallet balance + runway, instance count, next step (`choose_org`/`fund`/`deploy`/`connect_domain`), and the chosen org's own `funding_url`. Composed from existing reads. |
| `organizations_create` | any | Create a team org (name + slug, reserved slugs refused), the actor as owner; scopeless like the org list — the actor policy and the 10-org cap are the gate. |
| `apps_list` | `catalog:read` | The deployable app catalog, one entry per app. |
| `apps_show` | `catalog:read` | One catalog app by its URL slug: its versions (default allocation, `monthly_cents`) and the agent manual — the newest version's env contract (`configurable_env_vars` names/defaults), `first_run`, `backing_services`, OIDC wiring env names, default allocation and server-computed default price. |
| `pricing_quote` | `catalog:read` | A truthful quote for a custom allocation — `cpu`, `memory_mb`, `storage_gb` in, monthly/stopped cents out; the platform computes it. A deploy at the recommended size bills the manual's default quote instead. |
| `instances_list` | `instances:read` | Your instances, one entry each; an optional `organization` (id or slug) narrows to that org. |
| `instances_status` | `instances:read` | One instance's full detail by id (including `url`) — or, with no id, the verbose list. |
| `instances_deploy` | `instances:write` (+ `catalog:read` for the app/version resolve) | Deploy an app: resolve the slug, pick the newest version (or an exact one), resolve the organization (named, or sole-org fallback), create the instance (you name it, optional `env` map), enqueue the deploy. |
| `instances_configure` | `instances:write` | Merge env vars on a live instance: `set` adds/replaces, `remove` deletes. Values are write-only. |
| `instances_stop` | `instances:write` | Scale to zero — the pause (storage keeps accruing). |
| `instances_start` | `instances:write` | Start a stopped/sleeping instance back up. |
| `instances_resize` | `instances:write` | Stopped-first re-allocation: stop when running, resize, start; previous/new allocation plus the platform's price quote. A partial failure reports the step and the actual state. |
| `instances_destroy` | `instances:write` — **confirm-gated** | Destroy an instance and all its data, after a yes/no confirmation. |
| `gateway` | `gateways:read` (+ `gateways:write` for attach/detach) | The org's access gateway: `status`, `attach`, `detach`; pairing answers include the re-read status. |
| `custom_domain` | `gateways:read` (+ `gateways:write` for create/delete) | Register, verify (re-read), list, remove a custom domain; every row carries `live` and a `reason_code` (`platform`/guard states/claim-path states). |
| `sso` | `instances:read` (+ `instances:write` for connect) | Wire an instance to the org's Pocket ID and read the wiring back; identifiers only, never the minted secret. |
| `backups_status` | `backups:read` | An instance's backup settings + latest run. |
| `backups_configure` | `backups:write` | Save the backup destination (identifiers only — see below). |
| `backups_run` | `backups:write` | Run a backup now. |
| `backups_restore` | `backups:write` — **confirm-gated** | Restore a volume from the newest successful backup, after a yes/no confirmation. |
| `terraform_import_bundle` | `instances:read` (calls also need `backups:read` + `gateways:read`) | The Terraform import scaffold for an org: `versions.tf`, `imports.tf`, `README.md`. Read-only; returns the contents, writes nothing. Optional `api_url` for non-production platforms. |
| `wallet_balance` | `wallet:read` | The org wallet row. |
| `wallet_runway` | `wallet:read` | The runway projection (burn rate, hours left). |
| `wallet_ledger` | `wallet:read` | The ledger history, keyset-paginated (`next_cursor`). |
| `topup` | any | The panel's top-up URL — a pointer for the human, no API call. |

Tools are scope-filtered: `tools/list` uses the calling token's
EXACT scope list from GET /me's `meta.scopes` (one upstream read —
the OAuth middleware's validation read when the token is an OAuth
access token) and offers only what it covers —
`whoami`/`topup`/`organizations_create` for any live token,
each domain's tools under its scope, and a domain's `write` scope
implies its `read`. A zero-scope token still gets the scopeless tools.
The platform's own 403s are the real enforcement — a filtered-out
tool called directly still refuses, with the API's own message
verbatim (the funded-wallet gate included: agents hit the same gate
as the UI, no exceptions).

Logging is pinned: `ureq_proto` (HTTP heads, the Authorization header
included) and `rmcp` (the whole inbound request, tool arguments
included) stay at `info` regardless of `RUST_LOG`, so a trace/debug
export cannot leak a token or an env value. `RUST_LOG=info` is the
default; do not raise those two targets.

## Destructive tools: elicitation, honestly

`instances_destroy` and `backups_restore` confirm before acting, and
the first round checks the domain write scope before asking — a
read-only token gets its refusal without a human decision. The
mechanism is the MCP stateless-protocol elicitation (SEP-2322): the
first call answers with a yes/no confirm question naming the target;
the verb only runs when the client's answer is an explicit "yes".
"No", declining, or cancelling answers `cancelled. Nothing was
changed`. The confirmed target rides a sealed state blob that is
HMAC-bound to the calling token and expires after ten minutes — a
re-sent confirmation cannot steer a different id, and a seal from
another token never opens. The seal is TTL-bounded, not single-use —
an identical retry re-runs the verb.

A client that cannot confirm at all — anything not on the
2026-07-28 stateless protocol revision with the elicitation
capability declared — gets an honest error instead: `this client
cannot confirm destructive actions … or the panel. Nothing was
changed`. Never a silent no-op, never a crash, and the verb never
runs. Clients known to drive the full flow: rmcp-based clients (the
SDK retries the call with the answer automatically) and current
Claude clients; when in doubt, the panel's destroy/restore is the
fallback.

## Auth: OAuth, or a pasted PAT

The server is an OAuth 2.1 resource server (#766): an OAuth client that
sends no credential (or a dead access token) gets `401` with
`WWW-Authenticate: Bearer resource_metadata="…"`, discovers the
platform's authorization server, registers itself, and opens the
consent page. Approving mints a one-hour access token
(`fvoat_…`) and a rotating refresh token; the MCP client never sees a
paste-a-token step.

The protected-resource metadata lives at
`https://mcp.fluxvale.com/.well-known/oauth-protected-resource` (the
`/mcp`-suffixed path answers too): the resource identifier, the
authorization server, the supported scopes, and the header bearer
method. The platform serves RFC 8414 metadata at
`https://fluxvale.com/.well-known/oauth-authorization-server`.

OAuth access tokens are validated against the platform per request:
the middleware's `/me` read is both the proof and the scope source,
so a revoked connection refuses the next request with the same 401
challenge. The server holds no tokens, no session state, no secrets:
no env-var token, no keychain.

The pasted-PAT path still works unchanged — `Authorization: Bearer
fvpat_…` (Claude Desktop, Cursor, opencode's header config). Its
handlers keep their existing `/me` gates. Mint a PAT in the panel
with the scopes you want the agent to have when you want that model.

No tool parameter ever carries a secret — identifiers only. The
backup destination's S3 secret key and restic password are write-only
(#503): they are set in the panel and never ride this surface.

## Running

Env config, nothing else:

| Variable | Meaning | Default |
| --- | --- | --- |
| `MCP_PORT` | The port the server binds on 0.0.0.0. | `4600` |
| `FLUXVALE_API_BASE_URL` | The platform origin the tools call. Required. | — |
| `MCP_ALLOWED_HOSTS` | Comma-separated `Host` headers the DNS-rebinding guard admits. Unset or blank = rmcp's loopback-only default — a bare dev shell needs nothing. Never allow-all. Exact hosts only, optional `:port` — **no wildcards (a wildcard entry admits nothing)**. Add `localhost` alongside the ingress host if you `kubectl port-forward`. | — |
| `MCP_PUBLIC_URL` | The public MCP endpoint (the RFC 9728 resource identifier) advertised in protected-resource metadata. | `https://<first allowed host>/mcp`; a bare run uses `http://localhost:<port>/mcp`. |
| `MCP_AUTHORIZATION_SERVER` | The platform issuer advertised next to the resource. | Derived from the public host: prod → `https://fluxvale.com`, staging → `https://staging.fluxvale.com`, local k3d → `https://app.fluxvale.lvh.me`; anything else → `FLUXVALE_API_BASE_URL`. |

Against a local platform (the repo-root stack):

```sh
export FLUXVALE_API_BASE_URL=http://127.0.0.1:4000
cargo run --manifest-path apps/mcp/Cargo.toml
# -> MCP path  http://localhost:4600/mcp
# -> health    http://127.0.0.1:4600/health  (no auth; probes)
```

Point your MCP client's FluxVale server config at `/mcp`. Modern
clients discover OAuth from the 401 challenge; a client without OAuth
support can still send the PAT as the bearer token:

```json
{
  "mcpServers": {
    "fluxvale": {
      "url": "http://localhost:4600/mcp",
      "headers": { "Authorization": "Bearer fvpat_…" }
    }
  }
}
```

The serving posture is stateless: every POST is independent, the
request's own bearer answers it, no `Mcp-Session-Id` is issued. Both
protocol shapes work — the initialize handshake (protocol revs up to
2025-11-25) and the 2026-07-28 stateless flow (`server/discover`,
per-request metadata).

Note for deployment: rmcp's DNS-rebinding guard only accepts loopback
`Host` headers by default. `MCP_ALLOWED_HOSTS` (W3a) is the
deployment knob for that — it names exactly the hosts a deployment
serves (`StreamableHttpServerConfig`'s allowed hosts); the k3d
manifest sets `mcp.fluxvale.lvh.me`. `/health` rides the outer
router, deliberately OUTSIDE the guard — probes carry no `Host` a
deployment could pre-authorize, and a probe must never depend on the
protocol layer's health.

## Running in k3d

The repo-root local stack carries the server
(`deploy/local/k8s/16-mcp.yaml` — image built by the Tiltfile):
`tilt up`, then the MCP endpoint is
`https://mcp.fluxvale.lvh.me/mcp` — self-signed TLS through Traefik,
the same certificate posture as the platform's
`app.fluxvale.lvh.me` — and `https://mcp.fluxvale.lvh.me/health` for
probing. The deployment points `FLUXVALE_API_BASE_URL` at the
in-cluster platform service and sets
`MCP_ALLOWED_HOSTS=mcp.fluxvale.lvh.me`, so the guard admits exactly
the hostname the IngressRoute routes.

## Deployed (fleet #157)

- **W3b landed** (fluxvale/fleet#157) — the staging and prod
  manifests are live: `https://mcp-staging.fluxvale.com/mcp` and
  `https://mcp.fluxvale.com/mcp` (the protocol path — `MCP_PATH`
  above). Both hosts are live; the staging host is one label so the
  zone's `*.fluxvale.com` Universal SSL covers the edge.

## Gates

From `apps/mcp`: `cargo fmt --all -- --check`, `cargo clippy
--workspace --all-targets -- -D warnings`, `cargo test --workspace`,
`cargo deny check licenses advisories` — the same set CI runs
(`.github/workflows/ci.yml`, the `mcp-gates` job), with coverage
folded into that job (flag `mcp`).
