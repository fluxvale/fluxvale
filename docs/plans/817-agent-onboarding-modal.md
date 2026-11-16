# Plan: the agent handoff becomes an onboarding modal; agent docs stay public (#817)

Status: AT THE START GATE — awaiting Terence's go. Steer revised Nov 16
evening: Polar's pattern (a button that opens a modal with the prompt),
and the agent docs stay public under `/docs`. The earlier
force-the-account framing (auth-scope `/docs/agents`, redirect to
sign-up) is dropped; D5 records why nothing warrants keeping any of it.

Survey: the handoff page (`apps/platform/lib/flux_vale_web/live/agent_live.ex`),
the prompt source of truth (`apps/platform/lib/flux_vale_web/agent_prompt.ex`),
the public twin (`apps/platform/lib/flux_vale_web/controllers/agent_docs_controller.ex`
+ `agent_docs_html/show.html.heex`), the machine surfaces
(`controllers/llms_txt_controller.ex`, router `:text_plain` pipeline),
the first-run flow (session writes: `controllers/session_controller.ex`,
`controllers/google_controller.ex`, `live/auth_live/invite_accept.ex`;
the landing: `controllers/page_controller.ex` + `live/dashboard_live.ex`),
the sidebar (#801: `controllers/docs_html.ex`), the components
(`components/core_components.ex`), and the tests over all of the above.

## D1. The button lives in the dashboard's first-run empty state

The first-run flow today, verified: passwordless JIT signups and Google
signups land at `/` — `session_controller.ex:119` and
`google_controller.ex:171` both redirect to `return_to || ~p"/"`; invite
acceptances land at `/agent` once (`invite_accept.ex`'s hidden
`return_to`). There is no steps machine, no persisted onboarding state,
anywhere — #765's stance ("a dismissal needs no stored flag") plus a
derived-only MCP `onboarding_status`.

So the onboarding integration is one surface: the dashboard's fresh
state (`instance_count == 0`) — the empty state ("No instances yet …
finish setup with your agent", `dashboard_live.ex:206-214`) plus the
welcome-credit callout. The inline **"finish setup with your agent"
link becomes the button** that opens the modal in place. Testid becomes
`dashboard-agent-button` (it is a button now); the one test file that
asserts the old testid updates in the same slice.

First-run path coverage: JIT/Google signup → dashboard → button;
invite acceptance → the full `/agent` page, unchanged (a page beats a
modal there, and the flow already lands them on it). Every first-run
path reaches the handoff.

Rejected: a dedicated onboarding card (duplicates the empty state that
is already the first-run anchor); a forced step / gating plug with
stored completion (re-litigates #765's no-stored-flag decision; the
modal is the entire integration by the revised steer).

## D2. What the modal renders — one panel, extracted, cannot fork

Extract AgentLive's body (the copy-the-prompt section, the client
snippets grid, "What it will do", the spend-rule callout) into a
function component `FluxValeWeb.AgentPanel`
(`apps/platform/lib/flux_vale_web/components/agent_panel.ex`), plus
`org_from_assigns/1` — the personal-org resolution currently private in
`agent_live.ex:182-190` — so page and modal share one definition.
`/agent` renders the component inside its existing chrome; its
"I'll explore myself" card stays on the page, not the modal. All
existing `/agent` testids move with the component, byte-identical.

The modal renders the same component with a header, a close control,
and an "Open the full page" link to `/agent`. Org-specific data
(`AgentPrompt.context/2`, `prompt/1`, `clients_with_code/1`) is
computed in the open-modal `handle_event` from the same `OrgNav`
assigns the page uses (`actor_orgs`, `personal_org_id` —
DashboardLive declares `OrgNav` itself, `dashboard_live.ex:59-60`).

Orgs vs the single first user: no branching. Every account owns a
personal org from birth
([ADR-0042](../adr/00042-user-created-organizations.md)) — invitees
included (`accept_invitation` provisions it) — and the resolution
already falls back to the first membership, then to placeholder values
for legacy no-org accounts (pinned by `agent_live_test.exs:100-117`).

## D3. Dismissal and re-show — derived, never stored

The modal closes on its button, Escape, and backdrop click. Nothing
persists. The button stands exactly as long as the fresh state does
(`instance_count == 0` — the same derived condition as the empty state
and the wallet nudge), then goes with it. Post-onboarding homes are the
existing ones, unchanged: `/agent` (always linked from the modal),
`/settings/agents` (the quickstart), `/docs/agents` (the public doc).

## D4. The modal component

No modal exists in the app today (grep: none in `live/` or
`core_components.ex`) — this introduces the house pattern. Add `<.modal>`
to `core_components.ex`: fixed overlay + panel, `role="dialog"`,
`aria-modal="true"`, `aria-labelledby`, Escape via
`phx-window-keydown` and backdrop close via `phx-click` (the
`phx-click-away` precedent is `billing_live/topup.ex:721`). LiveView
assign-driven (`:if` on a boolean; `show`/`hide` events) — no JS hooks,
no inline scripts. Content is server-rendered from `AgentPrompt`.

## D5. `/docs/agents` stays public — auth-gating dropped, with evidence

The revised steer rules the docs public
([ADR-0044](../adr/00044-public-docs-surface.md) shape). Coupling
evidence says keeping it public is also the zero-churn path: the three
surfaces share exactly one artifact, `FluxValeWeb.AgentPrompt` — no
shared controller, plug, or template. `/agent` is gated by its
live_session `on_mount` (router.ex:404-415), `/llms.txt` rides its own
`:text_plain` pipeline (router.ex:46-52, 283), `/docs/agents` rides
`:public_seo` (router.ex:324-331). Nothing about the docs page's route
shape reaches the machine surfaces: `llms.txt`'s body and the prompt's
`Reference:` line embed the path as data
(`agent_prompt.ex:192,252`), the path is not changing, and the golden
fixture (`test/fixtures/agent_prompt.txt:19`) plus the every-link-200
loop (`llms_txt_controller_test.exs:32-44`) stay green untouched. The
page was never in the sitemap (`sitemap_xml.ex:45-61`), so there is no
link-rot or SEO posture to state. Nothing warrants gating: the only
motivation (force-the-account) was withdrawn with the steer.

## D6. Tidying under `/docs`

The sidebar entry stands as shipped (#801): "Set up with your agent",
first nav entry, active on `/docs/agents` (`docs_html.ex:25-49`,
pinned by `docs_controller_test.exs:69-79`); the literal-before-`:section`
route order stands. Two small adds: `/docs/agents` gains a
signed-in-only line "Open your personalized panel → `/agent`"
(`MaybeResolveUser` already resolves `current_user` on `:public_seo` —
a link is display-only use, honoring the pipeline's never-a-gate
comment), and `docs/mcp.md`'s first-run section names the modal as the
in-app first-run surface. No copy anywhere says the guide is gated.

## Slices

Each lands as its own PR (`Closes #817` only on the last), own worktree
branch, `mix ci` green before review. S1 → S2 are sequential (component
dependency); S3 is parallel (no file overlap with S1/S2). Fresh
worktree recipe per app AGENTS.md: `mix deps.get`, then
`MIX_ENV=test mix ash.setup` (and `mix ash.setup` for dev).

### S1 — extract `AgentPanel` (pure refactor, zero behavior change)

Files: new `apps/platform/lib/flux_vale_web/components/agent_panel.ex`
(panel body + `org_from_assigns/1`); `apps/platform/lib/flux_vale_web/live/agent_live.ex`
(component renders through it; private `personal_org/1` deleted).
Spec: `/agent`'s rendered DOM keeps every testid and class it has today
(`agent-panel`, `agent-prompt`, `agent-prompt-copy`, `agent-clients`,
`agent-client-*`, `agent-what-it-will-do`, `agent-spend-rule`,
`agent-snippet-note`, `agent-dismiss`) — the existing tests are the
refactor's proof and must pass UNCHANGED. No new tests.
Done when: `agent_live_test.exs` passes without edits;
`MIX_TEST_PARTITION=s1 mix ci` green.

```sh
cd apps/platform
MIX_TEST_PARTITION=s1 mix test test/flux_vale_web/live/agent_live_test.exs
MIX_TEST_PARTITION=s1 mix ci
```

### S2 — the onboarding button + modal

Files: `components/core_components.ex` (`<.modal>` per D4);
`live/dashboard_live.ex` (`dashboard-agent-button` in the empty state,
`show-agent-modal`/`close-agent-modal` events, org-specific assigns at
open, modal rendering `AgentPanel` + "Open the full page" link);
`test/flux_vale_web/live/dashboard_live_test.exs`.
Spec: fresh account (`instance_count == 0`) shows the button; clicking
opens `[data-testid="agent-modal"]` containing the same org-named
prompt and snippets as `/agent` (assert the shared testids inside the
modal, and that the prompt names the personal org); close button,
Escape, and backdrop each close; a deployed account shows neither
button nor modal; `/agent` page unchanged. Credo on the touched files
early (new component + core_components edit). PR carries captures per
the owner rules — light+dark stills of the fresh dashboard and the open
modal, plus a GIF of open/close (motion rule) — via
`node apps/e2e/capture.mjs` (click-through steps; images under
`docs/screenshots/<pr>/`, embedded with absolute raw URLs).
Done when: all S2 assertions pass; screenshots + GIF render in the PR
body; `MIX_TEST_PARTITION=s2 mix ci` green.

```sh
cd apps/platform
MIX_TEST_PARTITION=s2 mix test test/flux_vale_web/live/dashboard_live_test.exs
MIX_TEST_PARTITION=s2 mix ci
```

### S3 — docs tidy

Files: `controllers/agent_docs_controller.ex` (moduledoc names the
modal as the first-run surface; no behavior change);
`controllers/agent_docs_html/show.html.heex` (signed-in-only
"Open your personalized panel" → `/agent`);
`docs/mcp.md` (first-run section: the handoff renders at `/agent`,
`/docs/agents`, `/llms.txt` — and opens as a dashboard modal on first
run); `test/flux_vale_web/controllers/agent_docs_controller_test.exs`
(signed-in render shows the link; anonymous render exactly as today).
Done when: all existing `/docs/agents` and sidebar tests pass
unchanged; the new signed-in assertion passes; anonymous output is
byte-identical to today (no `<a href="/agent">` when signed out);
`MIX_TEST_PARTITION=s3 mix ci` green.

```sh
cd apps/platform
MIX_TEST_PARTITION=s3 mix test test/flux_vale_web/controllers/agent_docs_controller_test.exs
MIX_TEST_PARTITION=s3 mix ci
```

## Out of scope

Auth-scoping, redirecting, or moving `/docs/agents` (dropped by the
steer; D5). Any onboarding steps machine, persisted completion state,
or gating plug (#765 stands). Changes to `/agent`, `/llms.txt`,
`/settings/agents`, the prompt fixture content, sitemap/OG entries,
the landing page CTAs (the anonymous → `/docs/agents` swap is already
right for public docs). New e2e specs (captures satisfy the PR rule;
LiveView tests cover the behavior). i18n beyond what the touched files
already do.

## Calls made (for Terence's review)

- The button replaces the empty state's inline link rather than adding
  a card — the empty state is the first-run anchor.
- Testid renamed `dashboard-agent-link` → `dashboard-agent-button`.
- The modal reuses the whole panel (snippets, what-it-will-do, spend
  rule), not just the prompt — the handoff is one unit; "explore
  myself" stays page-only.
- `/agent`, `/settings/agents`, `/docs/agents` all remain post-onboarding
  homes; the modal adds a surface, moves nothing.
