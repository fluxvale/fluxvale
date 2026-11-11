# ADR-0027: Admin surface — AshAdmin

**Status**: Accepted
**Date**: 2026-09-01

**Context**: admin surfaces were scattered across ADRs as "small admin
LiveViews" (flags in [ADR-0023](00023-day-one-gates.md), feedback moderation
in [ADR-0026](00026-feedback-board.md)). Review surfaced **AshAdmin**
(`ash-project/ash_admin`): the framework's own extension generating a CRUD
dashboard over Ash resources, built with LiveView. Crucially it runs entirely
**through Ash actions** — policies, validations, and audit hooks apply
automatically — which is the property that disqualifies the alternatives
(a Phoenix LiveDashboard custom page bypasses the action/policy path; a
hand-rolled LiveView rebuilds what the extension generates).

**Decision**:

1. **AshAdmin is the day-one admin surface** for every resource-backed admin
   need: feature flags, access rules, users/wallets/instance inspection,
   feedback moderation. Domains opt in via the admin extension; the
   consolidated record for the per-ADR fragments is here (ADR-0023 Am. 2,
   ADR-0026 Am. 1).
2. **Mounting**: one admin route (`/admin`), admin-gated in prod (route-level
   auth plus the resource policies), open in dev — where it doubles as the
   local flag-flipping surface (no seeding scripts).
3. **Security posture**: exposure is *opt-in per domain*, not blanket.
   Sensitive resources (Identity: User/Token) are excluded unless a concrete
   need appears, and read-only where possible. Mutations ride the same policy
   path as everything else — the admin gate adds no new authorization model.
4. **Actor impersonation** is the standard tool for verifying policy behavior
   live (paying-customer gates, access rules) before test harnesses exist.
5. **Scope rule**: purpose-built admin LiveViews are built only when workflow
   UX outgrows generated CRUD (curated flag view, duplicate-merge moderation
   board — both deferred, not deleted).

**Ops lens trio** (three tools, three jobs, all free/in-stack): **Grafana**
(trend, alerts, everything, from anywhere) · **Phoenix LiveDashboard**
(this node's BEAM, right now) · **AshAdmin** (domain data, act-as-user).

**Meta-lesson codified**: before building any admin-adjacent surface, check
the Ash extension ecosystem first — it is more complete than it looks. (The
hand-rolled LiveView was proposed in this very session before anyone checked.)

**Deferred**: which domains host `FeatureFlag`/`AccessRule` (and thus how
AshAdmin's navigation groups them) is settled with the domain-model cut
(OQ #1).

## Amendment 1 (2026-10-27): §2's prod mount built (#288) — gate mechanism, dev's "open", and the policy reality

§2 sanctioned the admin-gated prod mount; the first build (#288) settles
what §2 left open — including one premise §3 held that the dependency
does not deliver.

- **The gate is runtime and default-denied**, not `dev_routes` compile
  mounting: `/admin` compiles into every release (ADR-0010's same-image
  rule) and answers a bare 404 while `ADMIN_MOUNT_KEY` is unset — the
  TestInbox gate pattern, run *before* the browser pipeline so a closed
  surface negotiates nothing. The app side ships first; flipping
  staging on is a fleet-side follow-up (a BWS secret + the overlay env).
  The key is a secret, not a boolean: enabling requires a vault write,
  the value is never presented per-request, and the gate fails closed
  on blank and off-intent values ("false"/"0"/"off"/"no"). An on_mount
  hook re-checks gate + actor at every LiveView socket mount — without
  it a session token would outlive a gate close or demotion, since a
  socket never re-enters the router.
- **"Open in dev" reads as mounted without the env flip, not
  unauthenticated**: route-level auth is the platform-admin session in
  *every* env (the TestInbox discipline), served by the seeded
  `admin@fluxvale.com`.
- **§3's "mutations ride the same policy path" is corrected by
  measurement**: AshAdmin's `authorizing` toggle defaults OFF upstream
  (and is admin-toggled in the UI), so actions through the mount run
  `authorize?: false` — the mount is a **trusted-operator superuser
  surface**, and the §3 per-domain opt-out (Identity/Accounts stay
  out), not the resource policies, is the data boundary behind the
  route gate. That opt-out carries more weight than it sounds:
  AshAdmin ignores `public?(false)` and renders non-public columns of
  shown domains as table data (measured across Wallet/Instance/
  AccessGateway — including `AccessGateway.credential_secret_ref`;
  it names the Secret, never holds the key, but nothing on the mount
  should be treated as private). Flipping the toggle's default would
  be theater (any admin can toggle it back) and with no actor wired
  it only breaks the UI; the honest control is who mounts the surface
  at all.

§4's actor impersonation remains structurally unavailable on this mount:
AshAdmin's actor picker only offers resources with the admin `actor?`
flag inside *shown* domains, and §3 keeps Identity (User) out. A concrete
impersonation need reopens §3's "unless a concrete need appears" clause —
minimal `show_resources([User])` — as its own decision.

## Amendment 2 — the mount gate retires; auth is the gate (2026-11-01)

The §2 runtime mount gate (`ADMIN_MOUNT_KEY`, default-denied 404) is
RETIRED by owner decision: the admin surface is mounted in every
environment, and the platform-admin session is the gate. The
`AdminEnabled` plug, the config keys, and the closed-gate test arms are
removed with it.

What changes, honestly: the surface's *existence* is now visible — an
unauthenticated request to `/admin` answers the sign-in bounce (302)
instead of a bare 404. The 404-was-invisible posture was defense in
depth, not the security boundary; the boundary was and remains the
platform-admin auth plus the `AdminGate` socket re-check (which keeps
guarding the demotion window the key never could — it stays). One
operational seam disappears: staging's BWS-rendered key and the
"flip prod when ready" choreography are gone with the env var.

One operational seam appears, accepted: the surface ships ON in new
environments by default — worth remembering when a fresh environment
first serves traffic.

## Amendment 3 (2026-11-07): the custom dashboard takes /admin; the generated admins demote to debug subpaths

Issue #501, owner ruling: FluxVale builds its own operator surface on
the design system. The custom admin home lives at `/admin`, AshAdmin
moves to `/admin/ash`, and Phoenix LiveDashboard moves to
`/admin/debug/dashboard`.

Why: the friends beta makes the admin surface a daily tool. Daily
work means invites, catalog and pricing surgery, billing oversight, and
moderation. The component library and design system already exist, so a
purpose-built console is now cheap to build and the daily workflows
deserve real UX. The generated tools stay for emergency data surgery,
which is what they are good at.

The gate does not move: every surface on the mount keeps the exact same
triple gate (browser pipeline, the `:admin_auth` route pipeline, and
the `FluxValeWeb.AdminGate` on_mount socket re-check) and AshAdmin
keeps its current §3 opt-in domain set.

What does NOT change: the §3 opt-in posture for AshAdmin exposure, the
Identity/Accounts exclusion, AshAdmin's `authorize?: false`
trusted-superuser reality (Am. 1), and Am. 2's always-mounted stance.

## Amendment 4 (2026-11-08): the homepage cards retire; the console is sidebar sections

Owner ruling: the admin dashboard is organized as **sidebar sections**
on the account-settings sidebar's idiom (PR #568), and the /admin
homepage-cards layout is retired. Every custom /admin surface renders
the shared section sidebar (`FluxValeWeb.AdminShell`) — the generated
debug tools (AshAdmin, LiveDashboard) keep their own chrome, so a deep
link into them is an accepted nav dead-end until browser-back (the
breadcrumb-back follow-up is filed): live workflows at their routes,
workflows not yet built as honest Coming entries with no link (the
cards' honesty grammar, kept). `/admin` itself redirects to the first
live section — no homepage of its own. The remaining workflows
(billing #571, then feedback, orgs, gateways) land as sections in
later slices and flip their sidebar entries live when they do. The
gate does not move; Am. 3's triple gate stays on every surface.

## Amendment 5 (2026-11-11): the per-event demotion seam rides the generated tools too (#671)

Am. 3's "exact same triple gate" left the generated tools with the
mount-time re-check alone, so a platform admin demoted mid-session
kept acting through an already-open tab until the socket reconnected
— on AshAdmin including saves and destroys (Am. 1's trusted-superuser
posture). #671 extracts the console's per-event seam
(`FluxValeWeb.AdminDemotionGate`: every event re-resolves the actor
from the session; notifications halt quietly —
[ADR-0047](00047-platform-admin-authority.md) D4's doctrine, extended)
and mounts it after AdminGate on the ash_admin and live_dashboard
live_sessions too, so the gate stack is a quadruple on every admin
surface.

Measured honestly against LiveView's channel, the seam sees
VIEW-targeted events and info messages only, and neither vendor
layout renders a flash group — a refusal on a generated surface is
silent (the copy renders on the console alone). LiveDashboard: the
refresh tick halts and view-level events are refused, but the table
controls (search, sort, limit) are cid-targeted events that
push_patch, and a patch re-runs handle_params ungated — node
telemetry still refreshes on interaction under a dead session.
AshAdmin: the view-level chrome is refused; the rest of its
component-level UI — save/destroy forms, generic actions, table
filters — targets its own LiveComponents, and cid-targeted events
route straight to the component: no view-level hook can see them.
Both residues stand disclosed on #671; closing them needs a
socket-level answer (a periodic re-resolve that redirects, a
demotion broadcast, or a :handle_params gate), a posture decision
for the owner, not this slice. The seam's resolve cost is accepted:
a few queries per info message, including the dashboard's tick.
That decision lands as Am. 6 below, which adds the recheck as a
fifth arm on the generated sessions.

## Amendment 6 (2026-11-11): the residue's answer — periodic re-resolve + redirect, generated sessions only

Am. 5's open posture question is decided (the owner, morning of
Nov 11, 2026): the **periodic re-resolve that redirects** — 30s
cadence, on the two GENERATED live_sessions only. A demoted actor's
ash_admin or live_dashboard tab redirects out of the admin area
within the cadence; the custom console keeps its per-event posture
(ADR-0047 D4) and the seam's quiet info halt (Am. 5) — the doctrine
that already covers its own writes. The demotion broadcast and the
:handle_params gate — Am. 5's other two candidate answers — are not
built; role changes stay data-layer.

`FluxValeWeb.AdminDemotionRecheck` owns the mechanism: mounted
after AdminGate and before the AdminDemotionGate seam (the seam's
info halt is quiet, so the recheck must see the tick first or its
redirect never runs), it arms a `Process.send_after` tick against
the view's own process on connected mounts, re-resolves the actor
from the session every cadence, and redirects to /sign-in —
AdminGate's own mount answer — the moment the role check fails
(the channel honors a redirect set in a halted info hook). The
tick dies with the socket's mailbox, so nothing leaks and at most
one tick is outstanding. The cadence is app env
(`:admin_demotion_recheck_ms`, default 30_000), read per arm —
a runtime override applies within one tick.

Accepted costs, on record: one timer and one resolve per cadence
per open generated-tools socket (a passing tick halts inside the
recheck, so the seam behind it never sees it — one resolve per
tick, total); a UX change for the demoted admin — a working tab is
yanked to /sign-in within 30s rather than freezing quietly; and the
redirect is fail-closed like AdminGate's mount answer — ANY resolve
failure (a token-store or DB blip, not just a demotion) reads as
"not signed in" and ejects every open generated-tools tab within
one cadence, where the seam alone would have quiet-frozen through
the blip. #671's bound, restated: the window is per-event on custom
surfaces and at most one cadence on the generated ones — bounded,
not closed; a cid-targeted save still runs if it wins the race
against the next tick.
