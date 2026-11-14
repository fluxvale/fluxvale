# The MCP tool surface — quickstart, catalog, changelog

FluxVale as tools for AI agents ([#484](https://github.com/fluxvale/fluxvale/issues/484)):
the remote MCP server (the `apps/mcp` Rust crate — its
[README](../apps/mcp/README.md) owns the server's env, auth, and deploy
truth) serves FluxVale over MCP. OAuth-capable clients connect without
a pasted token: the server advertises the platform's authorization
server and the consent page asks you to approve. Clients without OAuth
keep the personal-access-token path. The in-app quickstart lives at
`/settings/agents` (#484 W5), one click from where the token is minted
(the developer settings page's API tokens section, #483 — moved to
`/settings/developer` by #638); this doc mirrors it and carries the
tool-surface record the app cannot: the catalog and the changelog
below.

Endpoints (the protocol nests at `/mcp` — `apps/mcp/src/main.rs`
`MCP_PATH`): prod `https://mcp.fluxvale.com/mcp`, staging
`https://mcp-staging.fluxvale.com/mcp`.

## Connect with OAuth (no pasted token)

The server is an OAuth 2.1 resource server ([ADR-0054](adr/00054-mcp-oauth.md)).
A client that supports remote MCP OAuth needs only the URL:

1. **Add the server**: `https://mcp.fluxvale.com/mcp` (staging:
   `https://mcp-staging.fluxvale.com/mcp`).
2. **Approve the consent page**: the client reads
   `/.well-known/oauth-protected-resource`, registers itself with the
   platform, and opens `https://fluxvale.com/oauth/authorize`. Sign in,
   then review the client name, the host it returns to, and the scopes
   in product language. **Allow** connects; **Deny** returns
   `error=access_denied` to the client and grants nothing.
3. **Done**: the client holds a one-hour access token and rotates a
   thirty-day refresh token. Revoke it any time in
   `/settings/developer#connected-apps`; disconnecting takes effect on
   the next MCP request (401).

The authorization server (`https://fluxvale.com`, staging
`https://staging.fluxvale.com`) advertises its metadata at
`/.well-known/oauth-authorization-server`: `S256` PKCE, public
clients (`token_endpoint_auth_methods_supported: ["none"]`),
authorization-code and refresh grants, and the scope catalog plus
`offline_access`. PKCE is mandatory, redirect URIs match exactly,
codes are single-use for 60 seconds, and the token is bound to the MCP
resource. A mismatched `resource` is `invalid_target`; a request that
omits it (older clients) binds the configured default.

## The token fallback (clients without OAuth)

1. **Mint a token** in the API tokens panel
   (`/settings/developer#api-tokens`): name it for the agent, pick its
   scopes, create it. The full token shows exactly once — copy it
   there.
2. **Point your client at the server**: paste the server URL and the
   token into one of the configs below. `fvpat_…` marks where the
   token goes in Claude's form; the Cursor and opencode snippets read
   it from `FLUXVALE_PAT` in your environment instead.

**Never commit a token.** The file snippets reference the token
through each client's env syntax (Cursor `${env:FLUXVALE_PAT}`,
opencode `{env:FLUXVALE_PAT}`) — set the variable in your shell
(`export FLUXVALE_PAT=fvpat_…`), and the committed config carries no
secret.

Claude Desktop — no config file; a remote server is a custom
connector (`claude_desktop_config.json` is the local-stdio
mechanism). Customize → Connectors → **Add custom connector**:

1. Name: `FluxVale`
2. URL: `https://mcp.fluxvale.com/mcp`
3. Auth: pick **OAuth** when the client offers it (or
   **No sign-in** for the PAT fallback below)
4. Fallback only: request headers `Authorization: Bearer fvpat_…`

Cursor (`.cursor/mcp.json` per project, `~/.cursor/mcp.json`
everywhere — same shape either way; the token rides
`${env:FLUXVALE_PAT}`, never the file):

```json
{
  "mcpServers": {
    "fluxvale": {
      "url": "https://mcp.fluxvale.com/mcp",
      "headers": {
        "Authorization": "Bearer ${env:FLUXVALE_PAT}"
      }
    }
  }
}
```

opencode — **requires v2** (the `mcp.servers` shape; v1 uses a
different layout — upgrade rather than hand-edit). `opencode.json`
per project, `~/.config/opencode/opencode.json` everywhere; entries
nest under `mcp.servers` — direct-under-`mcp` entries are silently
dropped; `protocol: "auto"` because the default `legacy` caps at
2025-11-25 and the destructive tools' confirmations need the
2026-07-28 stateless revision; `oauth: false` in this fallback
because the snippet sends the PAT header — OAuth-capable clients
use the flow above. The token rides `{env:FLUXVALE_PAT}`, never the
file:

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
          "Authorization": "Bearer {env:FLUXVALE_PAT}"
        }
      }
    }
  }
}
```

**Scopes.** What the agent can do is what the token allows:
`tools/list` offers exactly the tools the token's scopes cover, write
includes read, and a zero-scope token still identifies itself. The
server reads the exact scope list from GET `/me`'s `meta.scopes`
(#585) — one upstream read per `tools/list`; for an OAuth access
token the resource server's per-request validation read is that same
read. Some tools need two domains — the catalog table lists each
tool's exact set; mint (or request, on the consent screen) the union.
The scope meanings are listed at mint time in the panel and in
product language on the consent page.

**Destructive actions.** `instances_destroy` and `backups_restore`
confirm through the client before anything runs. A client that can't
show that confirmation gets a clear error and nothing changes — the
panel is the fallback.

## The tool catalog

Twenty-six tools at the current surface. Scope-filtered per token: a
tool the token's scopes don't cover never appears in `tools/list`
(and a direct call still refuses — the platform's own 403s are the
enforcement). The scope column is the FULL set the tool needs — a
tool that makes several API calls needs every scope its calls
require (the server's `tools/list` gate is per-tool and may offer a
tool on its primary scope alone; the platform's route scopes are
the enforcement, so mint the union):

| Tool | What it answers | Scope | Gated |
| --- | --- | --- | --- |
| `whoami` | The identity the token carries: user id, email, platform role, username, organizations (id/slug/name) | any | — |
| `onboarding_status` | Account verified, organizations, the chosen org's wallet balance and runway, instance count, next step (`choose_org`/`fund`/`deploy`/`connect_domain`), and the chosen org's `funding_url` (its own top-up page) | `wallet:read` + `instances:read` (visibility on the wallet half) | — |
| `organizations_create` | Create a team org (name + slug; reserved slugs refuse), you as owner — scopeless like the org list; the actor policy and the 10-org cap are the gate ([ADR-0042](adr/00042-user-created-organizations.md)) | any | — |
| `apps_list` | The deployable app catalog, one entry per app | `catalog:read` | — |
| `apps_show` | One catalog app by its URL slug: its versions (default allocation, `monthly_cents`) and the agent manual — the newest version's env contract, first-run contract, backing services, OIDC wiring names, default allocation + server-computed default price | `catalog:read` | — |
| `pricing_quote` | A truthful quote for a custom allocation: `cpu`, `memory_mb`, `storage_gb` in, monthly/stopped cents out — the ledger's curve, computed by the platform. A deploy at the app's recommended size bills the manual's default quote instead | `catalog:read` | — |
| `instances_list` | Your instances, one entry each; an optional `organization` narrows to that org | `instances:read` | — |
| `instances_status` | One instance's full detail by id (including its public `url`) — or, with no id, the verbose list | `instances:read` | — |
| `instances_deploy` | Deploy an app: resolve the slug, pick the version, resolve the org (named, or sole-org fallback), create the instance with an optional `env` map, enqueue the deploy | `catalog:read` + `instances:write` (reads the app + versions + orgs before it writes the instance) | — |
| `instances_configure` | Merge env vars on a live instance: `set` adds/replaces, `remove` deletes (values are write-only) | `instances:write` | — |
| `instances_stop` | Scale to zero — the pause (storage keeps accruing) | `instances:write` | — |
| `instances_start` | Start a stopped/sleeping instance back up | `instances:write` | — |
| `instances_resize` | Stopped-first re-allocation: stop (when running), resize, start; previous/new allocation and the platform's price quote in the response | `instances:write` | — |
| `instances_destroy` | Destroy an instance and all its data | `instances:write` | confirm-gated |
| `gateway` | The org's access gateway: `status`, `attach`, `detach`; attach returns the pairing row, detach the result, both with the re-read status (`status_error` if that read failed) | `gateways:read` + `gateways:write` for attach/detach | — |
| `custom_domain` | `list`, `create`, `verify`, `delete` over the org's custom domains; every row carries `live`, `healthy`, and a `reason_code` (`platform`/`pending`/`failed`/`needs_attention`/`suspended`/`no_gateway`/`no_api_token`/`unclaimed`/`claimed`/`gateway_not_serving`/`removed`/`unknown`) | `gateways:read` + `gateways:write` for create/delete | — |
| `sso` | Wire an instance to the org's Pocket ID (`connect`) and read the wiring back (`status`); identifiers only, never the minted secret; a non-404 read-back failure rides as `status_error` beside the committed row (a 404 is an invisible row, not an error) | `instances:read` + `instances:write` for connect | — |
| `backups_status` | An instance's backup settings + latest run | `instances:read` + `backups:read` (the instance read gates first — the runs list alone can't name a foreign id) | — |
| `backups_configure` | Save the backup destination (identifiers only) | `backups:write` | — |
| `backups_run` | Run a backup now | `backups:write` | — |
| `backups_restore` | Restore a volume from the newest successful backup | `backups:write` | confirm-gated |
| `terraform_import_bundle` | Render a Terraform import scaffold (versions.tf, imports.tf, README.md) for an org's live instances, backups, gateway, custom domains, and PocketID SSO wirings; returns the file contents, writes nothing | `instances:read` + `backups:read` + `gateways:read` | — |
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

### 2026-11-14 — agent parity (#771)

- New `instances_resize`: the stopped-first sequence (stop when
  running, resize, start), CPU/RAM both ways, storage up-only. The
  response states the step reached, the instance's actual state, the
  previous/new allocation, and the platform's `/pricing/quote` figure
  (USD, monthly, billed hourly). A resize failure restarts the
  instance only when this call stopped it, reports both the failure
  and the final state, and answers `isError` with `ok: false`; an
  already-stopped row stays as it was. A no-op allocation or a
  storage shrink is refused before anything is stopped.
- New `gateway` over the org's one access gateway: `status`,
  `attach`, `detach`; attach returns the pairing row, detach the
  result, and both carry the re-read status, with any status-read
  failure in `status_error` beside the committed pairing.
- New `custom_domain`: `list`, `create`, `verify`, `delete`. Every
  row carries `live`, `healthy`, and a machine-readable
  `serving.reason_code`. The platform row is `platform` (fleet-served);
  a custom domain is live only while its gateway is active and its
  readable claim includes it, otherwise `no_gateway`, `no_api_token`,
  `unclaimed`, `gateway_not_serving`, or a guard state (`pending`,
  `failed`, `needs_attention`, `suspended`, `unknown`). A
  `needs_attention` domain with a live retained claim still serves
  (`live: true`, `healthy: false`). `verify` re-reads the row's state;
  issuance is the only verifier and this action triggers nothing. A
  gateway status-read outage rides as `serving_error` and never hides
  a committed registration.
- New `sso`: `status` answers `wired: false` for an unwired instance
  (after proving the instance is visible); `connect` mints the Pocket
  ID OIDC client, wires the env, and reads the durable row back. A
  failed read-back rides as `status_error` beside the committed
  connect row (a 404 is an invisible row, not an error) — a retry
  would re-mint. Identifier fields only — the
  minted client secret never rides the API or this tool.
- Platform: the gateway read gains `api_token_set` (the token stamp
  or the stored ref — a pre-stamp token still proves itself) and
  `claimed_domains` (the claims map's domain names; its values stay
  private), so the domain tool can name the claim-path reason rather
  than guess. Catalog count 22 → 26.

### 2026-11-13 — the agent first-run spine (#770)

- `apps_show` returns the app manual: the newest version's
  `configurable_env_vars` (names and catalog defaults only),
  `first_run`, `backing_services`, the default allocation, the OIDC
  wiring env names, and the default-size monthly/stopped price (the
  recommended Size row plus the storage axis — `Pricing.version_rates/1`,
  not a client formula).
- New `pricing_quote` (custom allocations, priced by
  `FluxVale.Pricing` server-side; a deploy at the recommended size
  bills the manual's default quote instead), `onboarding_status`
  (composed from existing reads — no new state — including the chosen
  org's `funding_url`), and `organizations_create` (the
  reserved-slug and org-cap rules are the server's; shipped scopeless
  like the org list, per [ADR-0042](adr/00042-user-created-organizations.md)
  Am. 1).
- `instances_list` takes an optional `organization`; `instances_deploy`
  takes one too, with the provider's sole-org fallback (several
  memberships without a name refuse, listing them).
- Platform: `POST /api/v1/organizations`,
  `GET /api/v1/app-versions/:id/quote`, `GET /api/v1/pricing/quote`,
  and `GET /api/v1/organizations/:organization_id/instances` join the
  machine API.

### 2026-11-13 — Terraform promotion

- `terraform_import_bundle` renders the same three-file scaffold as `fluxvale terraform import`: `versions.tf`, `imports.tf` (one import block per live instance, backup setting, gateway, and custom domain — plus commented PocketID SSO blocks, because provider 0.3.0 cannot import them — with each resource's own import-id shape), and `README.md`. Read-only, no filesystem writes. Pass `api_url` for staging; omit it for production. ([#763](https://github.com/fluxvale/fluxvale/issues/763))

### 2026-11-09 — the initial surface

- The initial surface's seventeen tools: `whoami`, `topup`, the catalog pair, the
  instances sextet, the backups quartet (destroy/restore
  confirm-gated), and the wallet trio. ([#484](https://github.com/fluxvale/fluxvale/issues/484) W2a+W2b)
- The in-app quickstart ships with the surface: `/settings/agents`,
  linked from the API tokens panel one click from the mint. ([#484](https://github.com/fluxvale/fluxvale/issues/484) W5)

### 2026-11-13 — the agent first run

- `instances_deploy` gains the write-only `env` map; `instances_configure`
  joins the instances surface as the in-place env merge (`set`/`remove`).
  Values never ride a response or a log. ([#765](https://github.com/fluxvale/fluxvale/issues/765))
- The post-registration handoff ships: `/agent` (the generated prompt and
  per-client snippets), `/docs/agents` (the public version), and
  `/llms.txt` (the machine-readable entry point) — all from one fixture. ([#765](https://github.com/fluxvale/fluxvale/issues/765))
