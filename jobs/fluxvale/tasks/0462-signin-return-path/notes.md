# 0462 sign-in return path

Issue fluxvale/fluxvale#462. PR fluxvale/fluxvale#477 (merged as cb9d355c).

## Outcome

A `return_to` query param travels the whole sign-in flow. Gated calls
to action link `/sign-in?return_to=<local path>`, the on_mount gate
carries the request path on direct hits to gated routes, the sign-in
LiveView rides the value through its one-shot POST in a hidden input,
and SessionController lands the visitor there on success (and re-links
sign-in with it on a failed write, so retries keep the destination).
No param means the default landing, unchanged.

`FluxValeWeb.ReturnPath` owns the local-only guard, and the guard is
*aligned to every downstream validator*: "/"-prefixed, no `//` or
leading `/\` (Chromium resolves `/\evil.com` cross-host), no backslash
or `/%09`/tab substring anywhere (Phoenix's `redirect(to:)` raises),
no newline or carriage return (Plug's header write raises). Non-local
values are silently ignored everywhere, falling back to `/`.

## What landed

- `FluxValeWeb.ReturnPath` (`local?/1`, `safe/1`, `sign_in_path/1`) —
  the shared guard; the notion cannot fork because every consumer
  rides it.
- `SessionController.create/2`: validated `return_to` on success,
  `ReturnPath.sign_in_path/1` on the failure arm.
- `AuthLive.SignIn`: validated query param at mount, hidden input in
  the verify form (POST body, never a re-emitted URL).
- `UserAuth.on_mount`: the gate's redirect carries the request path
  (query included) when the static render's connect_info is the conn;
  plain `/sign-in` on a connected remount.
- Link sweep: comments island, vote island, composer CTA, pricing Get
  started, the public chrome's navbar and footer links (a `return_to`
  assign from MaybeResolveUser passed through the twelve public SSR
  templates), the device-flow anonymous hop (panel section preserved),
  and both feedback islands via their live_render sessions (query
  kept, slug path as fallback).
- Deliberately unchanged: the landing's own CTAs (the landing already
  is the default target) and the authenticated chrome's sign-in links
  (they never render signed-out).

## Verification

- `mix ci` green on the final head: 3941 tests, credo strict, dialyzer
  0 errors, gettext check, coverage TOTAL 99.9% unchanged and every
  touched file at 100%.
- CI green on the PR: Platform CI, all three e2e legs, Docs lint,
  linked issues, codecov patches; mergeStateStatus CLEAN.
- The arc played for real: Playwright drove anonymous post page →
  comment CTA → passwordless code flow (code read through TestInbox) →
  landed back on the post, signed in. Stills light+dark and a GIF
  embedded in the PR body (`docs/screenshots/477/`).

## Review arc

- Hostile pass one (pre-PR, fresh subagent on GLM-5.3 Flash, Synthetic
  paused and disclosed in the PR body): caught `/\evil.com` passing the
  first guard. Verified empirically with a Chromium URL-parser probe
  before adopting: the browser lands on evil.com. Guard hardened, the
  table pins the shape.
- Hostile pass two (rate-limit substitute per the review-budget skill):
  caught the Phoenix validator mismatch (a mid-path backslash passed
  the guard and `redirect(to:)` would 500 a successful sign-in;
  reachable from a crafted public URL's query string), the failure-arm
  fork (retry lost the destination), a stale plug doc, and a
  dashboard-test arm documented. Its blocker-shaped "this reverts
  #474/#471" was a stale-base misread (the diff ran against an
  outdated main) and was rebutted against `git diff origin/main`.
- CodeRabbit: rate-limited at open — the check read "skipping", and
  the required status check blocked a standard merge. When the slot
  reset, the one `@coderabbitai review` was spent: verdict 4 minors,
  all adopted (newline refusal, query preservation on both islands,
  composer chrome target, plug doc), every thread replied in-place and
  resolved via GraphQL, walkthrough marker covered HEAD before merge.
  Adopted fixes landed as one push, no re-review.
- Freshness: main moved four times mid-flight (#390, #475, #474,
  #476). Rebased twice, `mix ci` re-run green after each rebase.

## Ops notes

- Port 4000 was occupied by another lane's beam; the capture server
  ran on 4123 (shut down after the merge). The worktree
  `../fv462-returnpath` still holds the lane checkout — the maintainer
  can `git worktree remove` it and drop the local branch after syncing
  main.
- Issue #462 did not auto-close on the merge despite `Closes #462` in
  the body (cross-referenced only); closed manually with the merge
  sha. Watch whether linked-issue closing behavior changed.
- Browser-flow capture recipe for sign-in: the stock `/dev/mailbox`
  route is not mounted here. Read codes through the admin-gated
  TestInbox JSON (`/test-inbox/api/mails/latest?email=…`) with an admin
  session minted the e2e-helper way (mix run script →
  `AshAuthentication.Jwt.token_for_user` on the seed admin → POST
  `/auth/session`).
- Playwright `recordVideo` screencast frames carry variable
  timestamps: a ~40s flow decoded to 2.3s of webm. Extract frames to
  PNGs and rebuild the GIF at a fixed framerate with
  palettegen/paletteuse, or the whole arc compresses into 2 seconds.
- gettext reference-line churn: any heex edit near `gettext` strings
  trips `mix ci`'s extract check. Run `mix gettext.extract --merge`
  after template edits, before the gate.
- Surfaced for triage (out of scope here): the platform-admin surfaces
  (`RequirePlatformAdmin`, `AdminGate`) still bounce anonymous
  visitors to plain `/sign-in` with no return path.
