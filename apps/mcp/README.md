# fluxvale-mcp

The FluxVale MCP server: FluxVale as tools for AI agents. Slices W2a
+ W2b of [#484](https://github.com/fluxvale/fluxvale/issues/484) —
the server core (rmcp streamable HTTP over the shared `/api/v1`
client crate `crates/fluxvale-api`, personal access token passthrough,
the read tools) plus the write surface: deploy through destroy, the
destructive pair elicitation-gated. W3a ships the container image,
CI publish, and the k3d exposure ([running in k3d](#running-in-k3d)).

## The tools (W2a + W2b)

| Tool | Scope | Answers |
| --- | --- | --- |
| `whoami` | any | The identity the token carries — user id, email, platform role, username, organizations (id/slug/name). |
| `apps_list` | `catalog:read` | The deployable app catalog, one entry per app. |
| `apps_show` | `catalog:read` | One catalog app by its URL slug. |
| `instances_list` | `instances:read` | Your instances, one entry each. |
| `instances_status` | `instances:read` | One instance's full detail by id — or, with no id, the verbose list. |
| `instances_deploy` | `instances:write` | Deploy an app: resolve the slug, pick the newest version (or an exact one), create the instance (you name it), enqueue the deploy. |
| `instances_stop` | `instances:write` | Scale to zero — the pause (storage keeps accruing). |
| `instances_start` | `instances:write` | Start a stopped/sleeping instance back up. |
| `instances_destroy` | `instances:write` — **confirm-gated** | Destroy an instance and all its data, after a yes/no confirmation. |
| `backups_status` | `backups:read` | An instance's backup settings + latest run. |
| `backups_configure` | `backups:write` | Save the backup destination (identifiers only — see below). |
| `backups_run` | `backups:write` | Run a backup now. |
| `backups_restore` | `backups:write` — **confirm-gated** | Restore a volume from the newest successful backup, after a yes/no confirmation. |
| `wallet_balance` | `wallet:read` | The org wallet row. |
| `wallet_runway` | `wallet:read` | The runway projection (burn rate, hours left). |
| `wallet_ledger` | `wallet:read` | The ledger history, keyset-paginated (`next_cursor`). |
| `topup` | any | The panel's top-up URL — a pointer for the human, no API call. |

Tools are scope-filtered: `tools/list` reads the calling token's
EXACT scope list from GET /me's `meta.scopes` (one upstream read) and
offers only what it covers — `whoami`/`topup` for any live token,
each domain's tools under its scope, and a domain's `write` scope
implies its `read`. A zero-scope token still gets the scopeless pair.
The platform's own 403s are the real enforcement — a filtered-out
tool called directly still refuses, with the API's own message
verbatim (the funded-wallet gate included: agents hit the same gate
as the UI, no exceptions).

Note that trace-level logging is unsafe on this server: a dependency
dumps HTTP heads at trace, the Authorization header included — cap at
`debug` (`RUST_LOG=info` is the default, and `ureq_proto` is pinned to
`info` regardless).

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

## Auth: PAT passthrough, nothing stored

The MCP client sends `Authorization: Bearer fvpat_…` on every request —
that is how Claude Desktop, Cursor, and opencode configure remote
servers. Each request's token is validated against the platform (a
dead token refuses at the protocol level) and then used per call.
The server holds no tokens, no session state, no secrets: no env-var
token, no keychain. Mint a PAT in the panel with the scopes you want
the agent to have.

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

Against a local platform (the repo-root stack):

```sh
export FLUXVALE_API_BASE_URL=http://127.0.0.1:4000
cargo run --manifest-path apps/mcp/Cargo.toml
# -> MCP path  http://127.0.0.1:4600/mcp
# -> health    http://127.0.0.1:4600/health  (no auth; probes)
```

Point your MCP client's FluxVale server config at `/mcp` with the PAT
as the bearer token:

```json
{
  "mcpServers": {
    "fluxvale": {
      "url": "http://127.0.0.1:4600/mcp",
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

## Coming later (not in this slice)

- **W3b** — the fleet-repo deploy of this image to staging/prod and
  the MCP gateway in front of it. (The image itself, its CI publish,
  and the k3d exposure above landed in W3a.)

## Gates

From `apps/mcp`: `cargo fmt --all -- --check`, `cargo clippy
--workspace --all-targets -- -D warnings`, `cargo test --workspace`,
`cargo deny check licenses advisories` — the same set CI runs
(`.github/workflows/ci.yml`, the `mcp-gates` job), with coverage
folded into that job (flag `mcp`).
