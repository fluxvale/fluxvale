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
