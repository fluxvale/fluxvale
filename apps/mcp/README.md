# fluxvale-mcp

The FluxVale MCP server: FluxVale as tools for AI agents. Slice W2a of
[#484](https://github.com/fluxvale/fluxvale/issues/484) — the server
core: rmcp streamable HTTP over the shared `/api/v1` client crate
(`crates/fluxvale-api`), personal access token (PAT) passthrough, and
the first five read tools.

## The tools (W2a)

| Tool | Answers |
| --- | --- |
| `whoami` | The identity the token carries — user id, email, platform role, username, organizations (id/slug/name). |
| `apps_list` | The deployable app catalog, one entry per app. |
| `apps_show` | One catalog app by its URL slug. |
| `instances_list` | Your instances, one entry each. |
| `instances_status` | One instance's full detail by id — or, with no id, the verbose list. |

Tools are scope-filtered: `tools/list` offers only what the token's
scopes cover (`whoami` for any live token, the apps pair under
`catalog:read`, the instances pair under `instances:read`; a write
scope implies its read). The platform's own 403 is the real
enforcement — a filtered-out tool called directly still refuses, with
the API's own message.

## Auth: PAT passthrough, nothing stored

The MCP client sends `Authorization: Bearer fvpat_…` on every request —
that is how Claude Desktop, Cursor, and opencode configure remote
servers. Each request's token is validated against the platform (a
dead token refuses at the protocol level) and then used per call.
The server holds no tokens, no session state, no secrets: no env-var
token, no keychain. Mint a PAT in the panel with the scopes you want
the agent to have.

No tool parameter ever carries a secret — identifiers only.

## Running

Env config, nothing else:

| Variable | Meaning | Default |
| --- | --- | --- |
| `MCP_PORT` | The port the server binds on 0.0.0.0. | `4600` |
| `FLUXVALE_API_BASE_URL` | The platform origin the tools call. Required. | — |

Against a local platform (the repo-root stack):

```sh
export FLUXVALE_API_BASE_URL=http://127.0.0.1:4000
cargo run
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
`Host` headers by default. W3's container deployment configures the
public hostnames (`StreamableHttpServerConfig`'s allowed hosts) — this
slice runs local only.

## Coming later (not in this slice)

- **W2b** — the write tools (deploy/stop/start, backups, gateway) with
  the destructive pair's confirmation flow, plus scope re-checks per
  write dispatch.
- **W3** — the container image, deployment, and the MCP gateway in
  front of it.

## Gates

From `apps/mcp`: `cargo fmt --all -- --check`, `cargo clippy
--workspace --all-targets -- -D warnings`, `cargo test --workspace`,
`cargo deny check` — the same set CI runs (`.github/workflows/ci.yml`,
the `mcp-gates` job), with coverage folded into that job (flag `mcp`).
