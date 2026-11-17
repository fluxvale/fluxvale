# Plan: onboarding collects the username, offers the agent, shows the loop (#831)

Status: SHIPPED — W1 landed as #833 (the stamp; the ADR-0047 policy
matrix documented in its PR body), W2 as #846 (the gate + flow, with
the e2e sign-in helpers learning the gate and a dedicated onboarding
spec). The e2e helper change surfaced a parked follow-up: capture.mjs
has not learned the gate (parked to the next screenshot-taking UI
lane). Kept as the decision record; the original plan-first framing
below is as it went to Terence's gate. Trigger, for the record:
Terence's first-run on the fresh post-wipe prod — the seeded first
user derives `admin-2` because `admin` is reserved, and no step let
the user choose.

Survey: `DeriveUsername` + `ValidUsername` + the `:set_username` action
(`contexts/identity/resources/user/…`), SettingsLive's rename (the
confirm-step pattern), seeds (`lib/flux_vale/seeds.ex` `create_admin/0`
— plain `:create`, so derivation runs), the session-write landing
points (`session_controller.ex:119`, `google_controller.ex:171`,
`invite_accept.ex:124`'s hardcoded `return_to=/agent`), the `/` swap
(`page_controller.ex`), #817's modal + `AgentPanel` (on
`feat/agent-onboarding-modal`, queued as #828), the user resource (no
onboarding state today — only invite lifecycle stamps), and the MCP
`onboarding_status` ladder (`apps/mcp/src/upstream.rs:275-283`).

## D1. The flow: `/onboarding`, three steps, one soft gate

A LiveView at `/onboarding` (the authenticated live_session), shown
once per user: **username → agent option → how-it-works → dashboard**.
Skip at any step finishes the flow — everything after the current step
is forgone, nothing blocks.

**Entry is the `/` swap, not an app-wide gate.** `PageController.home`'s
resolved-session arm gains one check: `onboarded_at == nil` → redirect
to `/onboarding`; otherwise dashboard as today. Deep links
(`/catalog`, `/apps/…`) stay reachable — no on_mount interception of
the app (the repo never built a gating plug; #817 kept that stance and
this keeps it). JIT and Google signups need no change: they land `/`
and the gate sends them on. The invite acceptance's hardcoded
`return_to=/agent` (#765) is repointed to plain `/` — the agent
handoff now lives INSIDE the flow, so #765's "fresh account lands on
the handoff" intent is preserved by construction (D5).

**Terence's admin-2 case resolves through the same gate**: the seeded
admin has `onboarded_at == nil`, signs in, lands `/`, gets the flow,
picks a real handle.

## D2. The username step — the rename machinery, pre-filled

The step pre-fills the account's CURRENT handle (the derived one) as
the suggestion. Accept = no-op; edit = the existing `:set_username`
action verbatim — `ValidUsername` (one regex, one reserved list),
owner-only policy, the unique-username identity as the race arbiter,
and SettingsLive's friendly conflict copy ("has already been taken").
No new validation, no forked rules. Derivation stays the fallback for
every path that skips the step — unchanged `DeriveUsername` on
`:create`/`:invite`.

The settings rename (`/settings`) stays exactly as it is: the
post-onboarding rename path, forever.

## D3. The agent step — #817's modal, reachable from the flow

Step 2 presents the paste-prompt: the same `AgentPanel` body in the
same `<.modal>` (or the step's own surface opening it — implementation
taste, one component either way), with the "Open the full page" link to
`/agent`. Nothing new is built; the flow embeds what #828 ships. The
dashboard's empty-state button remains untouched — it is the
post-onboarding path for skippers (#831's wording, honored literally).

## D4. `users.onboarded_at` — the app's first stored first-run bit

A private `utc_datetime_usec` attribute + migration (`mix ash.codegen`),
nil for every existing account. Set once — on finish OR skip (one
timestamp, no per-step state). This is the "never repeated for the
same user" guarantee for the whole flow including the walkthrough, and
it deliberately amends #765's no-stored-flag stance (D5). Seeded
accounts default nil — they get the flow too (that is the point).

## D5. What this supersedes and what it inherits

- #765's "a dismissal needs no stored flag" was about the `/agent`
  PAGE's dismissal — that stays true. The FLOW's show-once needs one
  bit (D4); the amendment is named here so nobody re-litigates it
  sideways.
- #765's invite-lands-on-`/agent` redirect is superseded by the flow
  (D1). The `/agent` page itself is untouched — always-reachable home
  of the prompt.
- #817's D3 ("no steps machine") held for the modal-only integration;
  #831 is the deliberate introduction of the flow, gated on the
  plan-first decision right here.
- The `/llms.txt` tension flagged in #817's D7 is untouched by this
  arc.

## D6. Machine surfaces and interplay, stated

- **MCP `onboarding_status` is unchanged** — the choose_org/fund/deploy/
  connect_domain ladder stands. A username step COULD slot ahead of the
  ladder someday; that is a machine-surface decision of its own, not
  smuggled in here. `/me` already exposes `username`, so agents see the
  chosen handle with zero changes.
- The org-slug asymmetry stands (a reserved USERNAME still lands a
  reserved org slug via provisioning — `ReservedSlug` never runs on
  that path); fixing that is out of scope, noted for the record.
- The walkthrough is static, no tour library (none exists; none gets
  vendored — repo rules). No JS hooks; LiveView-state stepping.

## Slices

Sequenced after #817's S4 merges (shared surfaces; the flow embeds the
S2 modal). Same gates as the 817 slices: worker
`MIX_TEST_PARTITION=wN`, `mix ci` green, pre-PR hostile pass, one
concern per PR, captures per the owner rules.

### W1 — the state (deploy-safe alone)

New `onboarded_at` (private `utc_datetime_usec` attribute, migration via
`mix ash.codegen add_users_onboarded_at`), a `:finish_onboarding`
update action (owner-only — NO admin bypass, onboarding is personal,
unlike `set_username`'s support path — sets the stamp server-side, no
client input), action tests including the no-admin-bypass pin.
Deliberately state-only: the gate redirects to `/onboarding`, and the
route does not exist until W2 — a gate without a route 404s fresh
signups in the window between merges (re-sliced Nov 17 for
deploy-safe intermediate states).
Done when: `MIX_TEST_PARTITION=w1 mix ci` green; the stamp exists,
owner-only, nil for every existing account; `/me` leaks nothing (the
attribute is private).

```sh
cd apps/platform
MIX_TEST_PARTITION=w1 mix test test/flux_vale/contexts/identity/user_test.exs
MIX_TEST_PARTITION=w1 mix ci
```

### W2 — the gate + the `/onboarding` flow (one deploy unit)

`PageController.home`'s nil-check redirect, the invite hardcode
repoint (`return_to` → `/`, #765 comment rewritten to name the flow),
the `/onboarding` route, and the LiveView: step machine in LiveView
state (username → agent → walkthrough), the D2 username step
(pre-filled, `:set_username`, the confirm-pattern armed only on
change), the D3 agent step (AgentPanel + modal reuse), the D4
walkthrough (static three-beat loop: pick from the catalog, deploy to
your box, manage the instance — skippable), finish/skip →
`:finish_onboarding` → dashboard. Gettext extraction rides the commit
(POT reference churn precedent). Tests: the gate (nil → redirect,
stamped → dashboard), invite acceptance lands through the gate, each
step's content and events, skip-at-any-step stamps and lands,
accept-derived-username is a no-op stamp, conflict copy, walkthrough
never re-renders once stamped. Captures: light+dark per step + the
finish hop; GIF if any transition animates (motion rule).
Done when: a fresh account walks username→agent→loop→dashboard end to
end; every skip path stamps and lands; `MIX_TEST_PARTITION=w2 mix ci`
green; captures embedded.

```sh
cd apps/platform
MIX_TEST_PARTITION=w2 mix test test/flux_vale_web/live/onboarding_live_test.exs
MIX_TEST_PARTITION=w2 mix ci
```

## Out of scope

The MCP `onboarding_status` ladder and any machine-surface username
step. The org-slug reserved-word asymmetry. Any change to `/agent`,
`/settings`, `/llms.txt`, `/docs/agents` (S4 owns the docs side).
Passwordless/Google/invite auth mechanics themselves. Re-showing or
re-entering the flow for finished accounts (the settings rename and
the dashboard button are the forever paths). Tour libraries.

## Calls made (for Terence's gate)

- One flow route, three steps, skip-anywhere: Polar-shaped, the
  walkthrough "never blocking" is within the flow, and the `/` gate is
  one nudge deep — no app-wide plug.
- ONE persisted bit (`onboarded_at`), not per-step state — the
  smallest honest store for "shown once".
- The username step reuses `:set_username` + `ValidUsername` verbatim;
  the suggestion is the derived handle.
- The invite flow's `/agent` landing is repointed through the gate —
  the handoff now lives inside onboarding.
- Seeded accounts get the flow (nil default) — Terence's admin-2 case
  is the first beneficiary.
