# Plan: the landing page says the machine-first thesis (#704)

Status: IMPLEMENTED on this branch for word review. The word gate holds:
no merge until Terence signs off on the copy. Copy verified against the
live surfaces on Nov 15 2026 (provider 0.4.0, MCP DNS live, CLI 0.1.0).

Survey: ADR-0019 ([Am. 3](../adr/00019-machine-first-api-cli-mcp.md) CLI,
[Am. 4](../adr/00019-machine-first-api-cli-mcp.md) provider, Am. 5 the Rust
MCP server), [ADR-0051](../adr/00051-tfprovider-repo-extraction.md) (the
provider's own repo), [ADR-0054](../adr/00054-mcp-oauth.md) (MCP OAuth),
the agent quickstart (#640, `/settings/agents`), the public agent handoff
(`/docs/agents`, `apps/platform/lib/flux_vale_web/agent_prompt.ex`), the
provider repo (v0.4.0 on the Terraform and OpenTofu registries),
`apps/cli/README.md`, the public docs pages
(`docs/public/automation/{mcp,terraform,cli}.md`), and the landing itself
(`apps/platform/lib/flux_vale_web/controllers/page_html/home.html.heex`).

## D1. The agent-first spine

**The page opens with the agent promise. The automation surfaces are part
of the spine, not a band after it.**

Before this change the hero sold a conventional managed PaaS ("Managed
cloud platform for open source applications", "Pick an open source app,
deploy it in minutes"). The page now reads as "built for agents, usable by
people":

1. **Hero**: your agent deploys, FluxVale runs it. The primary CTA is
   agent setup. The human path is a secondary catalog link.
2. **How it works**: one conversation, three steps. Ask for the app, the
   agent deploys it, FluxVale runs it.
3. **Ways in**: the surfaces close the how-it-works section. MCP is the
   lead card. Terraform and the CLI are compact secondary cards for humans
   who want the same API from code.
4. **Catalog**: the catalog the agent chooses from, with a human browse
   link.
5. **Pricing**: the flat rate the agent spends against. The agent can check
   the price before it deploys.

Above the fold: the four-layer hero keeps its layout and real product
capture; the H1, eyebrow, subhead, and primary CTA carry the new promise.
No hero rework beyond the words. The catalog is one click away, but it is
no longer the primary conversion path.

## D2. The copy

Copy rules: no em dashes, no semicolons, short plain sentences, no hype,
present tense for shipped things.

### Hero

- Eyebrow: `Built for agents`
- H1: `Your agent deploys. FluxVale runs it.`
- Sub: `Tell Claude Code, Cursor, VS Code, or any MCP client what you need. It picks the app from the catalog, deploys it, and hands you the URL. FluxVale keeps it running from there.`
- Primary CTA: `Set up your agent` → `/docs/agents` anonymous, `/settings/agents` signed in.
- Secondary CTA: `Browse the catalog` → `/catalog` anonymous. `Your dashboard` → `/` signed in.
- Header and footer gain `Agents` → `/docs/agents` anonymous, `/settings/agents` signed in.

The client list is the shipped one: `agent_prompt.ex` names Claude Code,
Cursor, and VS Code, and `/docs/agents` says "any MCP client".

### How it works

- Eyebrow: `How it works`
- H2: `One conversation to a running app`
- 01: `Ask for the app` / `Tell your agent what you need. It picks the app from the catalog.`
- 02: `The agent deploys` / `It deploys the app and hands you the URL.`
- 03: `FluxVale runs it` / `Updates, monitoring, backups, and private access are on us. Your data stays yours.`
- Catalog preview foot: `See the catalog` (was `Browse apps`).

### Ways in (inside the steps section)

- Eyebrow: `Ways in`
- Lead: `The agent is the default. Terraform and the CLI use the same API.`
- MCP card: `For your agent` / `MCP server` /
  `Claude Code, Cursor, VS Code, or any MCP client. OAuth clients connect with the URL and one approval. Clients without OAuth use a scoped token.` /
  `https://mcp.fluxvale.com/mcp` / `Set up your agent`
- Terraform card: `Terraform provider` /
  `Instances, backups, gateways, and custom domains as resources. The provider is on the Terraform and OpenTofu registries.` /
  `Provider guide`
- CLI card: `FluxVale CLI` /
  `One self-contained binary. Deploy, back up, check the wallet from the terminal.` /
  `CLI guide`

### Catalog and pricing

- Catalog eyebrow: `App catalog`
- Catalog H2: `The catalog your agent chooses from`
- Catalog sub: `Every app is ready to deploy. Your agent picks one, or you can browse the catalog yourself.`
- Catalog CTA: `Browse the catalog` (arrow link, not the primary button).
- Pricing H2: `One flat rate, no surprises` (unchanged).
- Pricing sub: `Prices follow the resources an app gets, not the app itself. Your agent can check the wallet and the price before it deploys. New accounts start with a welcome credit. Top up when you're ready.`
- Pricing CTA: `See full pricing` (unchanged).
- Pricing floor line: unchanged, computed from the size table.

### Page metadata

- Title: `FluxVale, your agent deploys open source apps`
- Description: `Tell your agent what you need. It picks an open source app from the catalog, deploys it, and FluxVale keeps it running.`
- Hero sr-only: `A screenshot of an app page as it runs on fluxvale.com.`

### The copy deck (before -> after)

Every changed visible string. Unchanged strings are not listed.

| Where | Before | After |
| --- | --- | --- |
| Hero eyebrow | Managed platform | Built for agents |
| Hero H1 | Managed cloud platform for open source applications | Your agent deploys. FluxVale runs it. |
| Hero sub | Pick an open source app, deploy it in minutes, and FluxVale keeps it running, updates and monitoring included. | Tell Claude Code, Cursor, VS Code, or any MCP client what you need. It picks the app from the catalog, deploys it, and hands you the URL. FluxVale keeps it running from there. |
| Hero primary CTA | Browse apps | Set up your agent |
| Hero secondary CTA | Sign in | Browse the catalog |
| Header nav | Apps, Pricing, Blog | Agents, Apps, Pricing, Blog |
| Steps H2 | Three steps to a running app | One conversation to a running app |
| Step 01 title | Pick an app | Ask for the app |
| Step 01 body | Choose from a curated catalog of open source applications, ready to run. | Tell your agent what you need. It picks the app from the catalog. |
| Steps catalog link | Browse apps | See the catalog |
| Step 02 title | Deploy | The agent deploys |
| Step 02 body | One guided flow from app to live URL. No YAML, no servers to babysit. | It deploys the app and hands you the URL. |
| Step 03 title | We run it | FluxVale runs it |
| Step 03 body | Updates and monitoring are on us. Your data stays yours. | Updates, monitoring, backups, and private access are on us. Your data stays yours. |
| Ways in lead | none | The agent is the default. Terraform and the CLI use the same API. |
| MCP card | none | For your agent / MCP server / Claude Code, Cursor, VS Code, or any MCP client. OAuth clients connect with the URL and one approval. Clients without OAuth use a scoped token. / https://mcp.fluxvale.com/mcp / Set up your agent |
| Terraform card | none | Terraform provider / Instances, backups, gateways, and custom domains as resources. The provider is on the Terraform and OpenTofu registries. / Provider guide |
| CLI card | none | FluxVale CLI / One self-contained binary. Deploy, back up, check the wallet from the terminal. / CLI guide |
| Catalog H2 | One click from browse to a running instance | The catalog your agent chooses from |
| Catalog sub | none | Every app is ready to deploy. Your agent picks one, or you can browse the catalog yourself. |
| Catalog CTA | Browse apps | Browse the catalog |
| Pricing sub | Prices follow the resources an app gets, not the app itself. New accounts start with a welcome credit. Top up when you're ready. | Prices follow the resources an app gets, not the app itself. Your agent can check the wallet and the price before it deploys. New accounts start with a welcome credit. Top up when you're ready. |
| Hero sr-only | A screenshot of the app catalog as it runs on fluxvale.com. | A screenshot of an app page as it runs on fluxvale.com. |
| Page title | FluxVale, managed cloud platform for open source applications | FluxVale, your agent deploys open source apps |
| Meta description | Browse a curated catalog of open source apps, deploy one in minutes, and let FluxVale keep it running for you. | Tell your agent what you need. It picks an open source app from the catalog, deploys it, and FluxVale keeps it running. |
| Footer | Apps, Pricing, Blog | Agents, Apps, Pricing, Blog |

## D3. Honesty ledger (claim -> shipped ground)

Verified Nov 15 2026 unless a row says otherwise.

| Claim | Ground |
| --- | --- |
| Your agent deploys, FluxVale runs it | MCP server `instances_deploy` deploys an app. FluxVale runs the instance. `docs/mcp.md` catalog (26 tools, Nov 14) |
| Claude Code, Cursor, VS Code, any MCP client | `agent_prompt.ex` names the three clients. `/docs/agents` says "any MCP client". The server is client-agnostic (streamable HTTP) |
| OAuth clients connect with the URL and one approval | [ADR-0054](../adr/00054-mcp-oauth.md). Live protected-resource metadata names `https://fluxvale.com` as the authorization server. Consent at `/oauth/authorize`, revoke at `/settings/developer#connected-apps` |
| Clients without OAuth use a scoped token | PAT fallback in `docs/mcp.md`: `Authorization: Bearer fvpat_…`, scopes at mint |
| Updates, monitoring, backups, private access are on us | The platform's managed runtime, backup and access surfaces (`docs/product.md`, the catalog benefits grid) |
| Terraform resources | Provider v0.4.0 registry docs: `fluxvale_instance`, `fluxvale_instance_backups`, `fluxvale_access_gateway`, `fluxvale_custom_domain`, plus `fluxvale_pocket_id_sso` |
| Terraform and OpenTofu registries | `registry.terraform.io/v1/providers/fluxvale/fluxvale`: v0.4.0 published 2026-11-14, protocol 6.0, four platforms, GPG-signed checksums. `registry.opentofu.org/v1/providers/fluxvale/fluxvale/versions`: v0.4.0, discovered 2026-11-14 |
| One self-contained CLI binary | `cli-v0.1.0` (latest CLI release, Nov 5): four platform archives, `SHA256SUMS`, `install.sh`. `apps/cli/README.md` covers deploy, backups, wallet |
| Every app is ready to deploy | The public catalog is the deployable set (`/catalog`, `apps_list`) |
| The agent can check the wallet and the price before it deploys | `wallet_balance`, `wallet_runway`, `pricing_quote`, and `apps_show` carry the reads. The first-run prompt checks the wallet and confirms spend (`/settings/agents`) |
| MCP URL printed on the page | `mcp.fluxvale.com` resolves today and `https://mcp.fluxvale.com/.well-known/oauth-protected-resource` returns 200. If DNS regresses, remove the line before merge |

Not claimed:

- Provider v0.5.0. The registry is v0.4.0. v0.5.0 is not released.
- Any CLI version number. The page names no version.
- Panel parity for the CLI. The card claims the daily loop, not every panel
  surface.
- Exact tool counts, protocol revisions, or registry platform counts in
  visible copy. They live in this ledger and the docs.

Known pre-existing gaps (reported, not fixed here):

- The CLI guide's `releases/latest/download/install.sh` one-liner 404s
  because the repo's `latest` release is `tf-v0.1.1`, not `cli-v0.1.0`.
  The tagged asset works. Fix the pointer before the landing sends traffic
  to the CLI page.
- The public MCP guide still says DNS is pending and points at support for
  the tool list. The host resolves and `docs/mcp.md` carries the catalog.
- `/settings/agents` still says gateways scopes do not unlock MCP tools.
  The gateway and custom-domain tools shipped in #771.

### Verification log

```sh
curl -s https://registry.terraform.io/v1/providers/fluxvale/fluxvale          # version 0.4.0
curl -s https://registry.terraform.io/v1/providers/fluxvale/fluxvale/versions # 0.2.1, 0.3.0, 0.4.0
curl -s https://registry.opentofu.org/v1/providers/fluxvale/fluxvale/versions # 0.4.0
getent hosts mcp.fluxvale.com                                                # resolves
curl -s -o /dev/null -w '%{http_code}\n' https://mcp.fluxvale.com/.well-known/oauth-protected-resource # 200
gh release list --repo fluxvale/fluxvale                                     # cli-v0.1.0 is the latest CLI release
curl -s -o /dev/null -w '%{http_code}\n' https://fluxvale.com/docs/agents    # 200
```

## D4. Captures

The change is visible, so before and after stills are mandatory:

- Before: the landing as it stood before the template change (identical to
  `origin/main` at the branch point), 1440x900 and 375x700, light and dark.
- After: the same four stills on the implemented branch, plus a 1440 hero
  viewport shot.
- Tool: `apps/e2e/landing_screenshot.mjs` (forces the resting state for
  scroll-linked reveals) against `FV_BASE=http://localhost:4000`.
- Files live under `docs/screenshots/<pr-number>/` on the PR branch and are
  embedded in the PR body as absolute raw URLs pinned to the branch.
- The screenshot table lists before/after per viewport/theme. The copy is
  the review subject; the captures prove the layout holds in both themes.

## D5. Implementation scope

One PR on `feat/landing-agent-surfaces`:

- `home.html.heex`: the agent-first spine, the ways block, the catalog and
  pricing framing.
- `page_controller.ex`: title and meta description.
- `landing.css`: the ways block, the balanced display h2, the catalog sub.
- `page_controller_test.exs`, `session_controller_test.exs`,
  `locale_test.exs`, `apps/e2e/tests/landing.spec.ts`: the new strings,
  agent-first CTAs, and the xx pseudo-locale entries.
- `default.pot` and the `en`/`xx` PO files: extracted and merged.
- This plan and the screenshots.

`mix ci` green. The page renders on the local stack. No reviewers, no
assignees, no merge. Terence reviews the words in the PR.

## D6. Calls made

- Kept the real catalog capture in the hero. The words carry agent-first,
  the image shows the product a human falls back to. A staged agent
  conversation would break the never-a-mockup rule.
- Folded the surfaces into the steps section as a "Ways in" block instead
  of a separate automation band. MCP leads; Terraform and the CLI are
  compact secondary cards.
- Printed the MCP URL because it resolves today. The plan's earlier draft
  kept it off the page while DNS was pending. If DNS regresses, remove it.
- Added `Agents` to the header and footer. The primary CTA is agent setup
  in the hero; the nav names the path.
- Changed the page title and meta description. Legal and policy pages keep
  their own "managed cloud platform" wording; the landing no longer uses
  it as its identity.
- Made the catalog CTA an arrow link, not a button. The primary conversion
  is the agent path; browsing is the human fallback.
- Softened the CLI claim to the daily loop. The CLI does not cover every
  panel surface (resize, custom domains, SSO).

## D7. Issue deltas (for the PA)

1. MCP tool count: 17 is now 26 (`docs/mcp.md`, Nov 14).
2. MCP auth is not PAT-only. OAuth 2.1 shipped (#766, ADR-0054).
3. Provider v0.2.1 is now v0.4.0 on both registries. v0.5.0 is not
   released.
4. Only instances is both a provider resource and a data source. Backups,
   gateways, domains, and SSO are resources.
5. MCP DNS is no longer pending. The host resolves and serves the OAuth
   metadata. The public MCP guide and the in-app quickstart note are stale.
6. The terraform guide dependency is resolved. The page teaches the
   registry flow and names v0.4.0 (#777).
7. The quickstart scope line is stale. Gateways scopes unlock MCP tools
   since #771.
8. The CLI install one-liner 404s. The release exists; the `latest` pointer
   is `tf-v0.1.1`.

## D8. Out of scope

MCP hosting and DNS, CLI and provider releases, the pricing page, the legal
pages, the MCP and CLI docs rewrites, and i18n beyond the gettext workflow.
