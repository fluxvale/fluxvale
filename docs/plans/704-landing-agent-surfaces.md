# Plan: the landing page says the machine-first thesis (#704)

Status: DRAFT — at the owner's word gate. Copy below is the deliverable;
nothing ships until the words are approved.

Survey: ADR-0019 ([Am. 3](../adr/00019-machine-first-api-cli-mcp.md) CLI,
[Am. 4](../adr/00019-machine-first-api-cli-mcp.md) provider, Am. 5 the Rust
MCP server), the agent quickstart (#640, `/settings/agents`),
`apps/tfprovider/docs/install.md`, `apps/cli/README.md`, the public docs
pages (`docs/public/automation/{mcp,terraform,cli}.md`), and the landing
itself (`apps/platform/lib/flux_vale_web/controllers/page_html/home.html.heex`).

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

## D2. The copy (ready to paste)

Every string below obeys D10: no em dashes, no semicolons, short plain
sentences. All of it lands as gettext msgids (`default.pot` + `en` + `xx`),
msgid as source of truth, per the landing's copy workflow.

### The band

- Eyebrow: `Automation`
- H2: `Your agent deploys, scales, and manages your apps`
- Sub: `FluxVale speaks MCP. Point your agent at it and it can browse the catalog, deploy an app, pause it, and check the wallet. Destructive actions ask first.`

Alternate sub (if the first reads too listy): `You do not have to click through any of it. Give your agent a scoped token and it does the work. Prefer code or a terminal? Those are here too.`

### The three cards

Card 1 — MCP (the agent track):

- Kicker: `For your agent`
- Title: `MCP server`
- Body: `Point Claude, Cursor, or any MCP client at FluxVale. Your agent lists the apps, deploys them, pauses them, and reads the wallet. A scoped token is the whole setup.`
- Link: `Agent setup` → `/settings/agents` when signed in, `/docs/automation/mcp` when anonymous (the hero CTA already branches on `@current_user`; same pattern)

Card 2 — Terraform (the codified track):

- Kicker: `For your stack`
- Title: `Terraform provider`
- Body: `Instances, backups, gateways, and custom domains become resources. Plan the stack, apply it, keep it in git.`
- Link: `Provider guide` → `/docs/automation/terraform`

Card 3 — CLI (the lazy track):

- Kicker: `For your terminal`
- Title: `FluxVale CLI`
- Body: `One self-contained binary. Sign in from the terminal, deploy an app, run a backup, check your runway. It is the panel, for when you would rather type.`
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

- Hero sub, appended sentence: `Or point your agent at it and skip the clicking.` (only if he wants the hint above the fold; recommendation is no)
- Meta description, appended: `Run it from your agent, Terraform, or the CLI.` (cheap SEO win, same honesty bar)
- Nav row addition: `Automation` → `/docs/automation` (the docs section index; the header currently carries Apps, Pricing, Blog)

## D3. Honesty ledger (claim → shipped ground)

| Copy claim | Ground |
| --- | --- |
| Agent browses catalog, deploys, pauses, reads wallet | MCP tools `apps_list`, `instances_deploy`, `instances_stop`, `wallet_*` (`docs/mcp.md`) |
| Destructive actions ask first | confirm-gated `instances_destroy`, `backups_restore` (ADR-0019 Am. 5) |
| Scoped token, revocable, token limits reach | PAT scopes + revocation (#360, Am. 1); `tools/list` filtered by grants |
| Instances, backups, gateways, custom domains as resources | `tf-v0.1.1` resource set (`docs/public/automation/terraform.md`) |
| One self-contained binary, deploy/backup/runway commands | `cli-v0.1.0` (`apps/cli/README.md`) |
| One API underneath | JSON:API is the substrate for all three clients (ADR-0019 §1) |

Not claimed anywhere: the `mcp.fluxvale.com` URL resolving today (DNS
pending rollout — the landing never prints the URL, it links the quickstart
and docs, which carry the note), a public Terraform registry install
(install doc teaches the release mirror), CLI version numbers, and any
`resize` verb on MCP (provider resizes; MCP scales to zero).

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
   stack serves MCP at `https://mcp.fluxvale.lvh.me/mcp`, `15-ingressroute.yaml`),
   mint a scoped PAT in the local panel, point an MCP client at the local
   server (opencode's `mcp.servers` snippet from `docs/mcp.md` with the local
   URL), ask it to deploy Kavita, record the terminal (Playwright `recordVideo`
   on a terminal or `ffmpeg` on a screen region), then `fps=12,scale=720:-1`
   per the GIF mechanics. Under 15s, trimmed to the conversation and the
   "Live at" line.
2. **The tofu apply flow** — terminal GIF. Recipe: provider `tf-v0.1.1`
   installed per `apps/tfprovider/docs/install.md` (release zip into the
   mirror, `~/.tofurc`), `FLUXVALE_PAT` minted locally, `api_url` pointed at
   the local stack, `examples/` shape .tf file, record `tofu apply` from plan
   to `Creation complete`. Same size discipline.

Fallback if the local cluster cannot run that day: the page stills satisfy
the capture rule (the change is a static section), the GIFs land in the PR
body by `gh pr edit --body-file` when produced, and the gap is reported
honestly. Nothing on the page itself embeds media (page-weight discipline,
screenshot-staleness risk from the catalog plan).

## D5. Slices

1. **Copy PR** (the whole lane if the owner approves the words as drafted):
   the band in `home.html.heex`, gettext entries (`default.pot`, `en`, `xx`),
   `landing.css` additions only if the existing card classes need a variant,
   controller test assertions (`page_controller_test.exs` gains the new
   strings and both link targets), optional e2e assertion in
   `landing.spec.ts`. Page stills embedded in the PR body, absolute URLs
   pinned to the branch, table-first per the screenshot format. `mix ci`
   green. No LiveView work exists in this lane — the landing is a dead view.
2. **Captures**: same PR per the repo's PR-shape conventions (captures ride
   the body of the PR that changes the surface). The demo GIFs are body
   additions, not code, so they can join by `gh pr edit` without a re-review
   if produced after the PR opens.
3. **Structural follow-ups** (separate, only if the owner takes an add-on):
   nav row or hero sentence ride the same copy PR anyway — they are one line
   each, not slices. Anything beyond (a dedicated `/automation` marketing
   page, GIFs on the page) is out of scope and a new issue.

## D6. Out of scope

Registry listing, MCP DNS rollout, CLI/provider releases (all tracked on
their lanes), the pricing page, the docs pages' content, i18n beyond the
gettext workflow.
