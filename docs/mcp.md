# The MCP tool surface — quickstart, catalog, changelog

FluxVale as tools for AI agents ([#484](https://github.com/fluxvale/fluxvale/issues/484)):
the remote MCP server (the `apps/mcp` Rust crate — its
[README](../apps/mcp/README.md) owns the server's env, auth, and deploy
truth) serves FluxVale over MCP with a personal access token. The
in-app quickstart lives at `/settings/agents` (#484 W5), one click
from where the token is minted (the developer settings page's API
tokens section, #483 — moved to `/settings/developer` by #638); this
doc mirrors it and carries the tool-surface
record the app cannot: the catalog and the changelog below.

Endpoints (the protocol nests at `/mcp` — `apps/mcp/src/main.rs`
`MCP_PATH`; DNS records pending rollout — if a URL doesn't resolve
yet, the endpoint is rolling out): prod
`https://mcp.fluxvale.com/mcp`, staging
`https://mcp.staging.fluxvale.com/mcp`.

## The recipe (two steps, one token)

1. **Mint a token** in the API tokens panel
   (`/settings/developer#api-tokens`): name it for the agent, pick its
   scopes, create it. The full token shows exactly once — copy it
   there.
2. **Point your client at the server**: paste the server URL and the
   token into one of the configs below. `fvpat_…` marks where the
   token goes.

Claude Desktop — no config file; a remote server is a custom
connector (`claude_desktop_config.json` is the local-stdio
mechanism). Customize → Connectors → **Add custom connector**:

1. Name: `FluxVale`
2. URL: `https://mcp.fluxvale.com/mcp`
3. Request headers: `Authorization: Bearer fvpat_…`

Cursor (`.cursor/mcp.json` per project, `~/.cursor/mcp.json`
everywhere — same shape either way):

```json
{
  "mcpServers": {
    "fluxvale": {
      "url": "https://mcp.fluxvale.com/mcp",
      "headers": {
        "Authorization": "Bearer fvpat_…"
      }
    }
  }
}
```

opencode (`opencode.json` per project,
`~/.config/opencode/opencode.json` everywhere; entries nest under
`mcp.servers` — the V2 shape, direct-under-`mcp` entries are
silently dropped; `protocol: "auto"` because the default `legacy`
caps at 2025-11-25 and the destructive tools' confirmations need
the 2026-07-28 stateless revision; `oauth: false` because the
server's 401 is a bearer challenge, not an OAuth dance):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "fluxvale": {
        "type": "remote",
        "protocol": "auto",
        "url": "https://mcp.fluxvale.com/mcp",
        "oauth": false,
        "headers": {
          "Authorization": "Bearer fvpat_…"
        }
      }
    }
  }
}
```

**Scopes.** What the agent can do is what the token allows:
`tools/list` offers exactly the tools the token's scopes cover, write
includes read, and a zero-scope token still identifies itself. The
scope meanings are listed at mint time in the panel.

**Destructive actions.** `instances_destroy` and `backups_restore`
confirm through the client before anything runs. A client that can't
show that confirmation gets a clear error and nothing changes — the
panel is the fallback.

## The tool catalog

Seventeen tools at the initial surface. Scope-filtered per token: a
tool the token's scopes don't cover never appears in `tools/list`
(and a direct call still refuses — the platform's own 403s are the
enforcement).

| Tool | What it answers | Scope | Gated |
| --- | --- | --- | --- |
| `whoami` | The identity the token carries: user id, email, platform role, username, organizations (id/slug/name) | any | — |
| `apps_list` | The deployable app catalog, one entry per app | `catalog:read` | — |
| `apps_show` | One catalog app by its URL slug | `catalog:read` | — |
| `instances_list` | Your instances, one entry each | `instances:read` | — |
| `instances_status` | One instance's full detail by id — or, with no id, the verbose list | `instances:read` | — |
| `instances_deploy` | Deploy an app: resolve the slug, pick the version, create the instance, enqueue the deploy | `instances:write` | — |
| `instances_stop` | Scale to zero — the pause (storage keeps accruing) | `instances:write` | — |
| `instances_start` | Start a stopped/sleeping instance back up | `instances:write` | — |
| `instances_destroy` | Destroy an instance and all its data | `instances:write` | confirm-gated |
| `backups_status` | An instance's backup settings + latest run | `backups:read` | — |
| `backups_configure` | Save the backup destination (identifiers only) | `backups:write` | — |
| `backups_run` | Run a backup now | `backups:write` | — |
| `backups_restore` | Restore a volume from the newest successful backup | `backups:write` | confirm-gated |
| `wallet_balance` | The org wallet row | `wallet:read` | — |
| `wallet_runway` | The runway projection (burn rate, hours left) | `wallet:read` | — |
| `wallet_ledger` | The ledger history, keyset-paginated (`next_cursor`) | `wallet:read` | — |
| `topup` | The panel's top-up URL — a pointer for the human, no API call | any | — |

## Tool-surface changelog

The discipline (mirroring the CLI's —
[apps/cli/CHANGELOG.md](../apps/cli/CHANGELOG.md)): **any tool add,
rename, or removal updates this file in the same PR** that changes
the surface. The server's behavioral detail (elicitation, sealing,
scope filtering) lives in the `apps/mcp` README; entries here name
the surface change and the PR.

### 2026-11-09 — the initial surface

- The seventeen tools above: `whoami`, `topup`, the catalog pair, the
  instances sextet, the backups quartet (destroy/restore
  confirm-gated), and the wallet trio. ([#484](https://github.com/fluxvale/fluxvale/issues/484) W2a+W2b)
- The in-app quickstart ships with the surface: `/settings/agents`,
  linked from the API tokens panel one click from the mint. ([#484](https://github.com/fluxvale/fluxvale/issues/484) W5)
