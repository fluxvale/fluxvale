# Plan: the landing page says the machine-first thesis (#704)

Status: DRAFT — at the owner's word gate. Copy below is the deliverable;
nothing ships until the words are approved. Copy re-verified against the
live surfaces on Nov 15 2026 (provider v0.4.0, MCP OAuth and live DNS,
CLI v0.1.0). §D7 lists the issue assumptions that moved.

Survey: ADR-0019 ([Am. 3](../adr/00019-machine-first-api-cli-mcp.md) CLI,
[Am. 4](../adr/00019-machine-first-api-cli-mcp.md) provider, Am. 5 the Rust
MCP server), [ADR-0051](../adr/00051-tfprovider-repo-extraction.md) (the
provider's own repo), [ADR-0054](../adr/00054-mcp-oauth.md) (MCP OAuth),
the agent quickstart (#640, `/settings/agents`), the provider repo
(`fluxvale/terraform-provider-fluxvale`, v0.4.0 live on
`registry.terraform.io/fluxvale/fluxvale` and the OpenTofu registry API),
`apps/cli/README.md`, the public
docs pages (`docs/public/automation/{mcp,terraform,cli}.md`), and the
landing itself
(`apps/platform/lib/flux_vale_web/controllers/page_html/home.html.heex`).

## D1. Where the pitch lands

**Recommend: a new dedicated section. No hero rework.**

The hero sells the broad promise (managed open source apps) to everyone;
reworking it around agents narrows the front door for the majority who
click. A section placed right after "How it works" markets the agent track
hard without touching what already converts, and the steps band sets up the
contrast for free: three steps for a human, or one sentence to your agent.

Placement: between the "How it works" bento and the catalog band. The
section is a dead-view band in the existing grammar (eyebrow, `display-h2`,
cards, `reveal`), same as the catalog band. No LiveView, no new routes, no
new JS. An `id="automation"` anchor on the band.

Above the fold: unchanged. The four-layer hero and the first steps band
keep the first screen; the automation band is the first band a scroller
meets after the steps. That is deliberate: the broad promise converts the
visitor who clicks, the automation band catches the visitor who came to
hand the work to an agent.

## D2. The copy (ready to paste)

Copy rules for every string below: no em dashes, no semicolons, short plain
sentences, no hype, present tense for shipped things. All of it lands as
gettext msgids (`default.pot` + `en` + `xx`), msgid as source of truth, per
the landing's copy workflow.

### The band

- Eyebrow: `Automation`
- H2: `Your agent deploys, scales, and manages your apps`
- Sub: `FluxVale speaks MCP. Point your agent at it and it can browse the catalog, deploy an app, pause or resize it, and check the wallet. Destructive actions ask first.`

Alternate sub (if the first reads too listy): `You do not have to click through any of it. Connect your agent and it does the work. Prefer code or a terminal? Those are here too.`

### The three cards

Card 1 — MCP (the agent track):

- Kicker: `For your agent`
- Title: `MCP server`
- Body: `Point Claude, Cursor, or any MCP client at FluxVale. Your agent lists the apps, deploys them, pauses or resizes them, and reads the wallet. OAuth clients connect with the URL and one approval. Clients without OAuth use a scoped token.`
- Link: `Agent setup` → `/settings/agents` when signed in, `/docs/automation/mcp` when anonymous (the hero CTA already branches on `@current_user`; same pattern)

Card 2 — Terraform (the codified track):

- Kicker: `For your stack`
- Title: `Terraform provider`
- Body: `Instances, backups, gateways, and custom domains become resources. The provider is on the public registry. terraform init and tofu init install it. Plan the stack, apply it, keep it in git.`
- Link: `Provider guide` → `/docs/automation/terraform`

  Earlier draft (pre-registry, for the record): the install sentence was
  absent and the ledger barred the registry claim. The listing went live
  Nov 11. It carries v0.4.0 since Nov 14, on the Terraform and OpenTofu
  registries.

Card 3 — CLI (the lazy track):

- Kicker: `For your terminal`
- Title: `FluxVale CLI`
- Body: `One self-contained binary. Sign in from the terminal, deploy an app, run a backup, check your runway. It covers the daily loop without the browser.`
- Link: `CLI guide` → `/docs/automation/cli`

### The honesty capsule

Same pattern as the pricing band's straddling capsule:

`One API underneath it all. Every path runs on a scoped token you can revoke. The agent only does what its token allows.`

### The mock panels (decorative, aria-hidden, literal)

One small mono block per card, matching the hero mock-panel pattern
(decorative, never extracted, `aria-hidden`). Version-free and domain-shaped
so they cannot drift:

- MCP (a conversation): `deploy kavita for me` / `Deploying Kavita.` / `Live at reading.fluxvale.app.`
- Terraform (apply output): `fluxvale_instance.reading: Creating...` / `fluxvale_instance.reading: Creation complete`
- CLI (a command): `fluxvale instances deploy --app kavita` / `Running`

### Optional add-ons (owner's call, each one line)

- Hero sub, appended sentence: `Or point your agent at it and skip the clicking.` (only if he wants the hint above the fold, recommendation is no)
- Meta description, appended: `Run it from your agent, Terraform, or the CLI.` (cheap SEO win, same honesty bar)
- Nav row addition: `Automation` → `/docs/automation` (the docs section index, live; the header currently carries Apps, Pricing, Blog)
- MCP server URL in card 1: `https://mcp.fluxvale.com/mcp` (the host resolves now, verified Nov 15; recommendation is still no, the quickstart owns the address)

### The msgids

Every string, exactly as it will be extracted. Optional strings are marked.

| # | msgid | Where |
| --- | --- | --- |
| 1 | `Automation` | band eyebrow |
| 2 | `Your agent deploys, scales, and manages your apps` | band H2 |
| 3 | `FluxVale speaks MCP. Point your agent at it and it can browse the catalog, deploy an app, pause or resize it, and check the wallet. Destructive actions ask first.` | band sub |
| 4 | `For your agent` | card 1 kicker |
| 5 | `MCP server` | card 1 title |
| 6 | `Point Claude, Cursor, or any MCP client at FluxVale. Your agent lists the apps, deploys them, pauses or resizes them, and reads the wallet. OAuth clients connect with the URL and one approval. Clients without OAuth use a scoped token.` | card 1 body |
| 7 | `Agent setup` | card 1 link |
| 8 | `For your stack` | card 2 kicker |
| 9 | `Terraform provider` | card 2 title |
| 10 | `Instances, backups, gateways, and custom domains become resources. The provider is on the public registry. terraform init and tofu init install it. Plan the stack, apply it, keep it in git.` | card 2 body |
| 11 | `Provider guide` | card 2 link |
| 12 | `For your terminal` | card 3 kicker |
| 13 | `FluxVale CLI` | card 3 title |
| 14 | `One self-contained binary. Sign in from the terminal, deploy an app, run a backup, check your runway. It covers the daily loop without the browser.` | card 3 body |
| 15 | `CLI guide` | card 3 link |
| 16 | `One API underneath it all. Every path runs on a scoped token you can revoke. The agent only does what its token allows.` | honesty capsule |
| 17 | `You do not have to click through any of it. Connect your agent and it does the work. Prefer code or a terminal? Those are here too.` | alternate band sub (not shipped) |
| 18 | `Or point your agent at it and skip the clicking.` | optional hero sentence |
| 19 | `Run it from your agent, Terraform, or the CLI.` | optional meta description tail |
| 20 | `Automation` | optional nav row (same msgid as 1) |

## D3. Honesty ledger (claim → shipped ground)

Verified Nov 15 2026 unless a row says otherwise.

| Copy claim | Ground |
| --- | --- |
| `FluxVale speaks MCP` | `apps/mcp` (Rust, streamable HTTP). Live `GET https://mcp.fluxvale.com/mcp` answers 401 with the bearer challenge, and `https://mcp.fluxvale.com/.well-known/oauth-protected-resource` returns 200 with `resource: https://mcp.fluxvale.com/mcp` |
| Agent browses catalog, deploys, pauses or resizes, reads wallet | `docs/mcp.md` catalog (26 tools, Nov 14): `apps_list`, `apps_show`, `instances_deploy`, `instances_stop`, `instances_start`, `instances_resize`, `wallet_balance`, `wallet_runway`, `wallet_ledger` |
| Destructive actions ask first | `docs/mcp.md` and `apps/mcp/README.md`: `instances_destroy` and `backups_restore` are confirm-gated (SEP-2322) |
| OAuth clients connect with the URL and one approval | [ADR-0054](../adr/00054-mcp-oauth.md). Live protected-resource metadata names `https://fluxvale.com` as the authorization server and lists the scopes. Consent page at `/oauth/authorize`, revoke at `/settings/developer#connected-apps` (`docs/mcp.md`) |
| Clients without OAuth use a scoped token | PAT fallback in `docs/mcp.md`: `Authorization: Bearer fvpat_…`, scopes chosen at mint |
| Scoped token, revocable, token limits reach | PAT scopes and revocation (ADR-0019 Am. 1). `tools/list` offers exactly the token's scopes, and the platform's 403s enforce. OAuth connections revoke from Developer settings |
| Instances, backups, gateways, custom domains as resources | Provider v0.4.0 registry docs: `fluxvale_instance`, `fluxvale_instance_backups`, `fluxvale_access_gateway`, `fluxvale_custom_domain`, plus `fluxvale_pocket_id_sso`. Data sources: `fluxvale_apps`, `fluxvale_app_versions`, `fluxvale_instance` |
| Provider on the public registry, `terraform init` and `tofu init` install it | `registry.terraform.io/v1/providers/fluxvale/fluxvale`: v0.4.0 published 2026-11-14, protocol 6.0, four platforms, GPG-signed checksums. `registry.opentofu.org/v1/providers/fluxvale/fluxvale/versions`: v0.4.0, discovered 2026-11-14 (the API is live, the UI path is not indexed yet). The public guide teaches the registry flow and names v0.4.0 (#777) |
| One self-contained binary, deploy, backup, runway | `cli-v0.1.0` is the latest CLI release (Nov 5): four archives, `SHA256SUMS`, `install.sh`. `apps/cli/README.md` lists `auth login`, `instances deploy`, `backups run`, `wallet runway`. Caveat: the repo's `latest` release pointer is `tf-v0.1.1`, so the documented `/releases/latest/download/install.sh` one-liner 404s today. The tagged `cli-v0.1.0` asset works |
| One API underneath | JSON:API is the substrate for all three clients (ADR-0019 §1) |

Not claimed anywhere:

- Version numbers. The provider is v0.4.0 and the CLI is 0.1.0, but the
  landing copy names neither. Versions belong in this ledger and the docs.
- The exact tool count. The copy says what an agent does, not how many
  tools exist.
- The MCP server URL on the page. The host resolves today, but the card
  links the quickstart, which owns the address. The print-the-URL add-on
  is the owner's call.
- Panel parity for the CLI. The card claims the daily loop. Resize,
  custom domains, and SSO wiring stay panel and Terraform paths.

### Verification log

```sh
curl -s https://registry.terraform.io/v1/providers/fluxvale/fluxvale          # version 0.4.0
curl -s https://registry.terraform.io/v1/providers/fluxvale/fluxvale/versions # 0.2.1, 0.3.0, 0.4.0, protocol 6.0, 4 platforms
curl -s https://registry.opentofu.org/v1/providers/fluxvale/fluxvale/versions # 0.4.0, discovered 2026-11-14
getent hosts mcp.fluxvale.com                                                # resolves (Cloudflare)
curl -si https://mcp.fluxvale.com/mcp                                        # 401 + WWW-Authenticate
curl -s https://mcp.fluxvale.com/.well-known/oauth-protected-resource        # 200, authorization_servers https://fluxvale.com
gh release list --repo fluxvale/fluxvale                                     # cli-v0.1.0 is the latest CLI release (the repo's latest is tf-v0.1.1)
curl -o /dev/null -w '%{http_code}\n' https://fluxvale.com/docs/automation/{mcp,terraform,cli,agents} # 200 each
```

### Docs and product copy that moved underneath this plan

- **Resolved**: the terraform guide (`docs/public/automation/terraform.md`,
  #777) now teaches the registry flow, names v0.4.0, and lists the full
  resource set. The dependency this plan flagged is gone.
- **Stale, docs lane**: `docs/public/automation/mcp.md` still says "DNS
  records pending rollout" and points at `support@fluxvale.com` for the
  tool list. The host resolves and `docs/mcp.md` carries the catalog.
- **Broken, release plumbing**: the CLI guide and README teach
  `https://github.com/fluxvale/fluxvale/releases/latest/download/install.sh`,
  but GitHub's `latest` release is `tf-v0.1.1`, which has no `install.sh`.
  The URL 404s. The tagged `cli-v0.1.0` install works. Fix the pointer (or
  the guide) before the landing sends traffic to the CLI page.
- **Stale, product copy**: `/settings/agents` still says "gateways scopes
  don't unlock MCP tools today" (the gateway and custom-domain tools
  shipped in #771 and the live metadata lists `gateways:read` and
  `gateways:write`). The same page's DNS note ("If the URL doesn't resolve
  yet...") is now stale.

## D4. Visual plan (captures)

Page stills (mandatory, per the screenshot rule — the surface change):

- Landing `/` before and after, light and dark, full page, 1440x900 —
  `node apps/e2e/capture.mjs https://app.fluxvale.lvh.me/ --out <dir>`
  against the local stack with the branch checked out (local server or k3d
  both fine; the page is anonymous, no token needed).
- The section anchor alone, light and dark, for the review thread (same
  run, `--viewport-shot` cropped by scroll to `#automation`).

Demo GIFs (the surfaces the section markets; motion is the point). Both are
real product flows on the local k3d stack, nothing staged or faked:

1. **An agent deploys an app** — terminal GIF. Recipe: `tilt up` (the local
   stack serves MCP at `https://mcp.fluxvale.lvh.me/mcp`,
   `15-ingressroute.yaml`), mint a scoped PAT in the local panel, point an
   MCP client at the local server (opencode's `mcp.servers` snippet from
   `docs/mcp.md` with the local URL), ask it to deploy Kavita, record the
   terminal (Playwright `recordVideo` on a terminal or `ffmpeg` on a screen
   region), then `fps=12,scale=720:-1` per the GIF mechanics. Under 15s,
   trimmed to the conversation and the "Live at" line. An OAuth-capable
   client can use the URL-only flow, but the PAT snippet is the reliable
   recording path.
2. **The tofu apply flow** — terminal GIF. Recipe: a plain `tofu init` —
   the registry listing is live (v0.4.0), so no mirror and no `~/.tofurc` —
   a small `.tf` in the provider repo's `examples/` shape, `FLUXVALE_PAT`
   minted locally, `api_url` pointed at the local stack, record `tofu
   apply` from plan to `Creation complete`. Same size discipline.

Fallback if the local cluster cannot run that day: the page stills satisfy
the capture rule (the change is a static section), the GIFs land in the PR
body by `gh pr edit --body-file` when produced, and the gap is reported
honestly. Nothing on the page itself embeds media (page-weight discipline,
screenshot-staleness risk from the catalog plan).

Capture verification (a vision pass over every still and GIF against the
claimed behavior) and any UI QA ride
`synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017`
(fleet routing note, Nov 11: burn the Synthetic pool there before its
Nov 16 sunset).

## D5. Slices

1. **Copy PR** (the whole lane if the owner approves the words as drafted):
   the band in `home.html.heex`, gettext entries (`default.pot`, `en`, `xx`),
   `landing.css` additions only if the existing card classes need a variant,
   controller test assertions (`page_controller_test.exs` gains the new
   strings and both link targets: `/docs/automation/mcp` anonymous,
   `/settings/agents` signed in), optional e2e assertion in `landing.spec.ts`.
   Page stills embedded in the PR body, absolute URLs pinned to the branch,
   table-first per the screenshot format. `mix ci` green. No LiveView work
   exists in this lane — the landing is a dead view.
2. **Captures**: same PR per the repo's PR-shape conventions (captures ride
   the body of the PR that changes the surface). The demo GIFs are body
   additions, not code, so they can join by `gh pr edit` without a re-review
   if produced after the PR opens.
3. **Structural follow-ups** (separate, only if the owner takes an add-on):
   nav row or hero sentence ride the same copy PR anyway — they are one line
   each, not slices. Anything beyond (a dedicated `/automation` marketing
   page, GIFs on the page) is out of scope and a new issue.

Review routing (fleet note, Nov 11): this PR is copy and visual by weight,
so the hostile review and the capture verification ride
`synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017` by preference;
`syn:large:text` stays the lane for code-depth review if the diff demands
it. Implementer host follows the cross-host rule (Z.AI implementers,
Synthetic reviewer).

## D6. Out of scope

MCP hosting and DNS (live, still tracked outside this lane), CLI and
provider releases (the provider tracks in its own repo since
[ADR-0051](../adr/00051-tfprovider-repo-extraction.md)), the pricing page,
the docs pages' content (the terraform guide is updated, the MCP guide's
stale notes are the docs lane's fix), i18n beyond the gettext workflow.

## D7. Issue deltas (for the PA)

The issue is grounded but eight of its facts or links moved after it was
written. Correct the issue so the next reader does not plan against them:

1. **MCP tool count**: 17 is now 26 (`docs/mcp.md`, Nov 14). The surface
   added resize, gateway, custom domains, SSO, pricing quote, onboarding,
   org create, env configure, and the Terraform import bundle.
2. **MCP auth**: not PAT-only. OAuth 2.1 shipped (#766,
   [ADR-0054](../adr/00054-mcp-oauth.md)): URL-only clients get discovery,
   consent, and a revocable connection. The PAT path remains the fallback.
3. **Provider version**: v0.2.1 is now v0.4.0, published Nov 14 on both
   `registry.terraform.io` and `registry.opentofu.org`. Protocol 6.0, four
   platforms, GPG-signed checksums.
4. **Provider data sources**: the issue says resources and data sources for
   instances, backups, gateways, and domains. Only instances is both.
   Backups, gateways, domains, and PocketID SSO are resources. Data sources
   are apps, app_versions, and instance.
5. **MCP DNS**: no longer pending. `mcp.fluxvale.com` resolves and serves
   the OAuth challenge and metadata. The public MCP guide and the in-app
   quickstart still say pending — both are stale.
6. **Terraform guide dependency**: resolved. The public guide now teaches
   `terraform init` / `tofu init` from the registry and names v0.4.0
   (#777).
7. **Quickstart scope line**: stale. Gateways scopes do unlock MCP tools
   now (#771). The in-app page says they do not.
8. **CLI install URL**: the release exists, but the documented
   `releases/latest/download/install.sh` one-liner 404s because the repo's
   `latest` release is `tf-v0.1.1`. Point it at `cli-v0.1.0` or make the
   CLI release latest before the landing links the guide.
