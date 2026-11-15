# Plan: the landing page tells both paths, human first (#704)

Status: A LOCKED per Terence's ruling. The hero panel is an HTML
dashboard preview, not a bitmap. The word gate holds: no merge until
Terence signs off on the copy. Live claims verified Nov 15 2026
(provider 0.5.0, MCP DNS live, CLI 0.1.0).

Survey: ADR-0019 ([Am. 3](../adr/00019-machine-first-api-cli-mcp.md) CLI,
[Am. 4](../adr/00019-machine-first-api-cli-mcp.md) provider, Am. 5 the Rust
MCP server), [ADR-0051](../adr/00051-tfprovider-repo-extraction.md) (the
provider's own repo), [ADR-0054](../adr/00054-mcp-oauth.md) (MCP OAuth),
the agent quickstart (#640, `/settings/agents`), the public agent handoff
(`/docs/agents`, `apps/platform/lib/flux_vale_web/agent_prompt.ex`), the
provider repo (v0.5.0 on the Terraform and OpenTofu registries),
`apps/cli/README.md`, the public docs pages
(`docs/public/automation/{mcp,terraform,cli}.md`), and the landing itself
(`apps/platform/lib/flux_vale_web/controllers/page_html/home.html.heex`).

## D1. The 50/50 split

**The regular-user path stays front and centre. The agent is the second,
equally weighted way to get the same thing.**

The page leads with the product as a normal person experiences it. The
agent enters as a peer option, not as the identity of the page:

1. **Hero**: pick an open source app, deploy it in minutes, FluxVale runs
   it. The agent is the second sentence and its own text link. The primary
   CTA is the human sign-up path.
2. **How it works**: two equal lanes. The human lane is first: pick an
   app, deploy, FluxVale runs it. The agent lane is beside it: ask, the
   agent deploys, FluxVale runs it. Same outcome.
3. **Ways in**: dashboard and agent side by side, equal cards. The
   dashboard is first. Terraform and the CLI are the code path below.
4. **Catalog**: a human line. The agent mention is secondary.
5. **Pricing**: neutral. The agent price check is a second sentence.

Above the fold: the hero keeps its four-layer layout. The panel is an
HTML dashboard preview with real catalog apps and statuses, not a
screenshot. The eyebrow, H1, subhead, and CTAs carry the human-first
promise. The agent is one text link away in the hero and fully present
in the lanes.

## D2. The hero (A, locked)

- Eyebrow: `Managed open source apps`
- H1: `Open source apps, running in minutes.`
- Sub: `Pick one from the catalog, deploy it, and FluxVale keeps it running. Or hand it to your agent. It can do the same from Claude Code, Cursor, VS Code, or any MCP client.`
- Primary CTA: `Get started` → `/sign-in` anonymous, `Your dashboard` → `/` signed in.
- Secondary CTA: `Browse the catalog` → `/catalog`.
- Agent link: `Have an agent? Set it up` → `/docs/agents` anonymous, `/settings/agents` signed in.

### The dashboard mock

The panel is an HTML/CSS dashboard preview, not an image. It derives from
the signed-in dashboard (`dashboard_live.ex`): title, deploy action,
wallet chip, app rows, status pills. It shows three real catalog apps:
Forgejo (Running), Umami (Running), Kavita (Sleeping). Each row carries
its local catalog icon, name, and instance hostname.

The wallet chip is a label only. No amount, no runway, no uptime, no
invoice, no email. The panel chrome is `aria-hidden`. The visible float
chip says `dashboard preview`; the sr-only line says
`A preview of the dashboard with several apps running, not a screenshot.`

The hostnames are `forgejo.fluxvale.app`, `umami.fluxvale.app`, and
`kavita.fluxvale.app`. This is a call: the direction said `fluxvale.com`,
but the marketing origin is `fluxvale.com` and instances run on
`fluxvale.app`. A `.com` hostname would be false. Terence can veto.

## D3. The rest of the copy

### How it works

- Eyebrow: `How it works`
- H2: `Two ways to a running app`
- Sub: `Pick an app yourself, or hand it to your agent. FluxVale runs it either way.`
- Human lane (first): `Do it yourself`
  - 01: `Pick an app` / `Choose from a curated catalog of open source applications, ready to run.`
  - 02: `Deploy` / `One guided flow from app to live URL. No YAML, no servers to babysit.`
  - 03: `FluxVale runs it` / `Updates and monitoring are on us. Your data stays yours.`
  - Catalog preview foot: `See the catalog`.
- Agent lane (second): `Or ask your agent`
  - 01: `Ask for the app` / `Tell your agent what you need. It picks the app from the catalog.`
  - 02: `The agent deploys` / `It deploys the app and hands you the URL.`
  - 03: `FluxVale runs it` / `Same platform. Same updates, backups, and private access.`
  - Foot: `Claude Code, Cursor, VS Code, or any MCP client.` + `Set up your agent`.

### Ways in

- Eyebrow: `Ways in`
- Lead: `Use the dashboard, or hand it to your agent. Terraform and the CLI are there for code.`
- Dashboard card (first): `For you` / `Dashboard` /
  `Pick an app, deploy it, and manage it from the panel. The wallet, backups, and access live there too.` /
  `Get started` anonymous, `Open the dashboard` signed in.
- Agent card (second): `For your agent` / `MCP server` /
  `Point Claude Code, Cursor, VS Code, or any MCP client at FluxVale. OAuth clients connect with the URL and one approval. Clients without OAuth use a scoped token.` /
  `https://mcp.fluxvale.com/mcp` / `Set up your agent`.
- Code row: `Terraform provider` /
  `Instances, backups, gateways, and custom domains as resources. The provider is on the Terraform and OpenTofu registries.` /
  `Provider guide`. `FluxVale CLI` /
  `One self-contained binary. Deploy, back up, check the wallet from the terminal.` /
  `CLI guide`.

### Catalog and pricing

- Catalog eyebrow: `App catalog`
- Catalog H2: `Pick an app. It's running in minutes.`
- Catalog sub: `Every app is ready to deploy. Browse the catalog yourself, or let your agent pick.`
- Catalog CTA: `Browse the catalog` (arrow link).
- Pricing H2: `One flat rate, no surprises` (unchanged).
- Pricing sub: `Prices follow the resources an app gets, not the app itself. Your agent can check the price before it deploys. New accounts start with a welcome credit. Top up when you're ready.`
- Pricing CTA: `See full pricing` (unchanged).

### Page metadata

- Title: `FluxVale, deploy open source apps from the dashboard or an agent`
- Description: `Pick an open source app from the catalog and deploy it in minutes. Or hand it to your agent from Claude Code, Cursor, VS Code, or any MCP client. FluxVale keeps it running.`
- Hero sr-only: `A preview of the dashboard with several apps running, not a screenshot.`
- Hero float chip: `dashboard preview`

### The copy deck (before -> after)

Every changed visible string. The human steps that were restored are
marked unchanged, not repeated.

| Where | Before | After |
| --- | --- | --- |
| Hero eyebrow | Managed platform | Managed open source apps |
| Hero H1 | Managed cloud platform for open source applications | Open source apps, running in minutes. |
| Hero sub | Pick an open source app, deploy it in minutes, and FluxVale keeps it running, updates and monitoring included. | Pick one from the catalog, deploy it, and FluxVale keeps it running. Or hand it to your agent. It can do the same from Claude Code, Cursor, VS Code, or any MCP client. |
| Hero primary CTA | Browse apps | Get started |
| Hero secondary CTA | Sign in | Browse the catalog |
| Hero agent link | none | Have an agent? Set it up |
| Hero float chip | real apps · real prices | dashboard preview |
| Hero panel | Bitmap app page (hero-app-page-light.png, hero-app-page-dark.png) | HTML dashboard mock: Dashboard, Deploy app, Wallet, Forgejo, Umami, Kavita, forgejo/umami/kavita.fluxvale.app, Running/Sleeping |
| Header nav | Apps, Pricing, Blog | Apps, Agents, Pricing, Blog |
| Footer | Apps, Pricing, Blog | Apps, Agents, Pricing, Blog |
| Steps H2 | Three steps to a running app | Two ways to a running app |
| Steps sub | none | Pick an app yourself, or hand it to your agent. FluxVale runs it either way. |
| Human lane label | none | Do it yourself |
| Human step 01 | Pick an app / Choose from a curated catalog of open source applications, ready to run. | unchanged |
| Human step 02 | Deploy / One guided flow from app to live URL. No YAML, no servers to babysit. | unchanged |
| Human step 03 title | We run it | FluxVale runs it |
| Human step 03 body | Updates and monitoring are on us. Your data stays yours. | unchanged |
| Steps catalog link | Browse apps | See the catalog |
| Agent lane label | none | Or ask your agent |
| Agent step 01 | none | Ask for the app / Tell your agent what you need. It picks the app from the catalog. |
| Agent step 02 | none | The agent deploys / It deploys the app and hands you the URL. |
| Agent step 03 | none | FluxVale runs it / Same platform. Same updates, backups, and private access. |
| Agent lane foot | none | Claude Code, Cursor, VS Code, or any MCP client. / Set up your agent |
| Ways in eyebrow | none | Ways in |
| Ways in lead | none | Use the dashboard, or hand it to your agent. Terraform and the CLI are there for code. |
| Dashboard kicker | none | For you |
| Dashboard title | none | Dashboard |
| Dashboard body | none | Pick an app, deploy it, and manage it from the panel. The wallet, backups, and access live there too. |
| Dashboard link | none | Get started / Open the dashboard |
| MCP kicker | none | For your agent |
| MCP title | none | MCP server |
| MCP body | none | Point Claude Code, Cursor, VS Code, or any MCP client at FluxVale. OAuth clients connect with the URL and one approval. Clients without OAuth use a scoped token. |
| MCP URL | none | https://mcp.fluxvale.com/mcp |
| MCP link | none | Set up your agent |
| Terraform title | none | Terraform provider |
| Terraform body | none | Instances, backups, gateways, and custom domains as resources. The provider is on the Terraform and OpenTofu registries. |
| Terraform link | none | Provider guide |
| CLI title | none | FluxVale CLI |
| CLI body | none | One self-contained binary. Deploy, back up, check the wallet from the terminal. |
| CLI link | none | CLI guide |
| Catalog H2 | One click from browse to a running instance | Pick an app. It's running in minutes. |
| Catalog sub | none | Every app is ready to deploy. Browse the catalog yourself, or let your agent pick. |
| Catalog CTA | Browse apps | Browse the catalog |
| Pricing sub | Prices follow the resources an app gets, not the app itself. New accounts start with a welcome credit. Top up when you're ready. | Prices follow the resources an app gets, not the app itself. Your agent can check the price before it deploys. New accounts start with a welcome credit. Top up when you're ready. |
| Hero sr-only | A screenshot of the app catalog as it runs on fluxvale.com. | A preview of the dashboard with several apps running, not a screenshot. |
| Page title | FluxVale, managed cloud platform for open source applications | FluxVale, deploy open source apps from the dashboard or an agent |
| Meta description | Browse a curated catalog of open source apps, deploy one in minutes, and let FluxVale keep it running for you. | Pick an open source app from the catalog and deploy it in minutes. Or hand it to your agent from Claude Code, Cursor, VS Code, or any MCP client. FluxVale keeps it running. |

## D4. Honesty ledger (claim -> shipped ground)

Verified Nov 15 2026 unless a row says otherwise.

| Claim | Ground |
| --- | --- |
| Pick an open source app, deploy it, FluxVale runs it | The public catalog, the deploy flow, and the managed runtime. The human lane restores the original steps |
| Or hand it to your agent | MCP server `instances_deploy` deploys an app. FluxVale runs the instance. `docs/mcp.md` catalog (26 tools, Nov 14) |
| Claude Code, Cursor, VS Code, any MCP client | `agent_prompt.ex` names the three clients. `/docs/agents` says "any MCP client". The server is client-agnostic (streamable HTTP) |
| OAuth clients connect with the URL and one approval | [ADR-0054](../adr/00054-mcp-oauth.md). Live protected-resource metadata names `https://fluxvale.com` as the authorization server. Consent at `/oauth/authorize`, revoke at `/settings/developer#connected-apps` |
| Clients without OAuth use a scoped token | PAT fallback in `docs/mcp.md`: `Authorization: Bearer fvpat_…`, scopes at mint |
| Dashboard: pick, deploy, manage, wallet, backups, access | The panel's own surfaces. The dashboard card is the human path |
| Terraform resources | Provider v0.5.0 registry docs: `fluxvale_instance`, `fluxvale_instance_backups`, `fluxvale_access_gateway`, `fluxvale_custom_domain`, plus `fluxvale_pocket_id_sso` |
| Terraform and OpenTofu registries | `registry.terraform.io/v1/providers/fluxvale/fluxvale`: v0.5.0 published 2026-11-15, protocol 6.0, four platforms, GPG-signed checksums. `registry.opentofu.org/v1/providers/fluxvale/fluxvale/versions`: v0.5.0 |
| One self-contained CLI binary | `cli-v0.1.0` (latest CLI release, Nov 5): four platform archives, `SHA256SUMS`, `install.sh`. `apps/cli/README.md` covers deploy, backups, wallet |
| Every app is ready to deploy | The public catalog is the deployable set (`/catalog`, `apps_list`) |
| The agent can check the price before it deploys | `pricing_quote` and `apps_show` carry the platform's quote. The first-run prompt checks the wallet and confirms spend (`/settings/agents`) |
| MCP URL printed on the page | `mcp.fluxvale.com` resolves today and `https://mcp.fluxvale.com/.well-known/oauth-protected-resource` returns 200. If DNS regresses, remove the line before merge |
| Hero dashboard preview | Derived from `dashboard_live.ex`: the Dashboard title, Deploy action, wallet chip, app rows, and status pills. Forgejo, Umami, and Kavita are real catalog apps. Icons are the local catalog files. Hostnames use `*.fluxvale.app`, the real instance domain |
| Mock honesty | The panel chrome is `aria-hidden`. The visible chip says `dashboard preview`. The sr-only line says it is a preview, not a screenshot. No amount, uptime, invoice, or email |

Not claimed:

- Provider v0.6.0 or anything beyond the live v0.5.0.
- Any CLI version number. The page names no version.
- Panel parity for the CLI. The card claims the daily loop.
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
curl -s https://registry.terraform.io/v1/providers/fluxvale/fluxvale          # version 0.5.0
curl -s https://registry.terraform.io/v1/providers/fluxvale/fluxvale/versions # 0.2.1, 0.3.0, 0.4.0, 0.5.0
curl -s https://registry.opentofu.org/v1/providers/fluxvale/fluxvale/versions # 0.5.0
getent hosts mcp.fluxvale.com                                                # resolves
curl -s -o /dev/null -w '%{http_code}\n' https://mcp.fluxvale.com/.well-known/oauth-protected-resource # 200
gh release list --repo fluxvale/fluxvale                                     # cli-v0.1.0 is the latest CLI release
curl -s -o /dev/null -w '%{http_code}\n' https://fluxvale.com/docs/agents    # 200
```

## D5. Captures

The change is visible, so before and after stills are mandatory:

- Before: the landing on `origin/main` before this branch (the old
  conventional page), 1440x900 and 375x700, light and dark.
- After: the 50/50 page on this branch with the HTML dashboard mock, the
  same four stills, plus a 1440 hero viewport shot. The before/after table
  shows the old bitmap panel against the new HTML dashboard.
- Tool: `apps/e2e/landing_screenshot.mjs` (forces the resting state for
  scroll-linked reveals) against `FV_BASE=http://localhost:4000`.
- Files live under `docs/screenshots/<pr-number>/` on the PR branch and are
  embedded in the PR body as absolute raw URLs pinned to the branch.
- The PR body lists before/after per viewport/theme. The copy is the review
  subject; the captures prove the layout holds in both themes.

## D6. Implementation scope

One PR on `feat/landing-agent-surfaces`:

- `home.html.heex`: the 50/50 hero, the HTML dashboard mock, the two
  lanes, the dashboard/agent Ways in block, the catalog and pricing
  framing.
- `page_controller.ex`: title and meta description.
- `landing.css`: the lanes, the equal Ways in cards, the code row, the
  dashboard mock.
- Delete `hero-app-page-light.png` and `hero-app-page-dark.png`; the
  panel was their only use.
- `page_controller_test.exs`, `session_controller_test.exs`,
  `locale_test.exs`, `apps/e2e/tests/{landing,root-session}.spec.ts`:
  the new strings and CTAs.
- `default.pot` and the `en`/`xx` PO files: extracted and merged.
- This plan, the refreshed screenshots, and the PR body deck.

`mix ci` green. The page renders on the local stack. No reviewers, no
assignees, no merge. Terence reviews the words in the PR.

## D7. Calls made

- Reordered the header and footer to Apps, Agents, Pricing, Blog. The
  agent link stays, but the human path comes first.
- Replaced the hero bitmap with an HTML/CSS dashboard mock. It derives
  from `dashboard_live.ex`, uses real catalog apps and local icons, and
  flips with the theme.
- Used `*.fluxvale.app` hostnames, the real instance domain. The direction
  said `fluxvale.com`; a `.com` hostname would be false. Terence can veto.
- Kept the wallet chip label-only. The mock has several apps running, so a
  balance number would be a fabricated metric.
- The visible chip says `dashboard preview`. The sr-only line says it is a
  preview, not a screenshot.
- Kept the mock labels literal. The panel is `aria-hidden`; the sr-only
  line carries the description.
- Deleted the two hero PNGs. They were used only in this template.
- Built the how-it-works section as two equal lanes, human first. The
  agent lane is the same three steps, not a replacement.
- Made the Ways in pair dashboard first, agent second, equal width.
  Terraform and the CLI sit below as the code path.
- Printed the MCP URL because it resolves today. The hero agent link and
  the MCP card are the agent path; the primary CTA is the human sign-up.
- Made the catalog CTA an arrow link, not a button. Browsing is the human
  fallback to the hero's primary.
- Kept the pricing band neutral. The agent price check is the second
  sentence.
- Softened the CLI claim to the daily loop. The CLI does not cover every
  panel surface.

## D8. Issue deltas (for the PA)

1. MCP tool count: 17 is now 26 (`docs/mcp.md`, Nov 14).
2. MCP auth is not PAT-only. OAuth 2.1 shipped (#766, ADR-0054).
3. Provider v0.2.1 is now v0.5.0 on both registries. v0.5.0 published
   Nov 15; the first pass saw v0.4.0.
4. Only instances is both a provider resource and a data source. Backups,
   gateways, domains, and SSO are resources.
5. MCP DNS is no longer pending. The host resolves and serves the OAuth
   metadata. The public MCP guide and the in-app quickstart note are stale.
6. The terraform guide dependency is resolved. The page teaches the
   registry flow and names the current provider line (#777).
7. The quickstart scope line is stale. Gateways scopes unlock MCP tools
   since #771.
8. The CLI install one-liner 404s. The release exists; the `latest` pointer
   is `tf-v0.1.1`.

## D9. Out of scope

MCP hosting and DNS, CLI and provider releases, the pricing page, the legal
pages, the MCP and CLI docs rewrites, and i18n beyond the gettext workflow.
