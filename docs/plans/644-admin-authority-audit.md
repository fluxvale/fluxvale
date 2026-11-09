# Plan: blanket admin authority + the paper trail (#644, #645)

Status: ACCEPTED — PA go relayed 2026-11-09, D1-D10 as recommended (rider
on D1: the doctrine gate in its strictest form, below; riders on D4/D6/D9
recorded at their decisions). Architect worktree `fv-644-adminpower`,
branch `feat/admin-authority-audit`. Two owner rulings, one doctrine (Nov 9):

> "Having an admin dashboard is pointless if an admin can't see everything.
> We can add more roles in the future that have less privileges if needed.
> But as admin, I should be able to do anything I want in the admin
> dashboard. That said, I think we should implement AshPaperTrail so we
> have auditing capabilities."

If the admin can do anything, every mutation is audited. Arc 1 widens
authority; Arc 2 makes the widening observable. Neither ships alone.

Related record: [ADR-0027](../adr/00027-admin-surface-ashadmin.md) (Am. 1's
`authorize?: false` reality is the starting honesty), the resource console
plan ([595](595-resource-console.md), slices in flight: #598 read path
merged, #617 write path in review), the read-arm escalations #577/#613, and
the console sections (#501 lane, ADR-0027 Am. 3-4). New ADRs when the arcs
land: ADR-0047 (authority) and ADR-0048 (audit).

## The business resource set (both arcs share ONE list)

35 resources live across the 9 configured domains. Both arcs act on the
same 29 — the business resource set — and exclude the same 6 machinery
resources by name, each with its reason:

| Domain | In the set | Excluded (reason) |
|---|---|---|
| Ops | FeatureFlag, AccessRule | — |
| Catalog | Category, App, AppVersion | — |
| Infrastructure | Cluster, Instance, BackupSetting, BackupRun, AccessGateway, AccessRoute, AccessDomain, InstanceHostname | InstanceAllocationSnapshot (append-only telemetry — the table IS its trail) |
| Pricing | Size, TaxRate | — |
| Billing | Wallet, LedgerEntry, Topup | — |
| Feedback | Post, Vote, Comment, Tag, PostTag | — |
| Identity | User, UserEmail, PersonalAccessToken | Token, AuthCode, DeviceCode (ephemeral auth machinery: minutes-to-days lifetime, secret-adjacent, AshAuthentication owns them) |
| Accounts | Organization, Membership, MembershipInvite | — |
| Api | — | AuditEvent (itself the machine-API audit), RequestWindow (janitor bookkeeping) |

One list, two doctrines: Arc 1's bypass lands on the 29; Arc 2's paper
trail versions the 29. A resource moves between sets only by amending this
table — the doctrine gate (below) fails CI on any unlisted resource, same
forcing function as the console registry's parity test.

### The doctrine gate (strictest form, per the PA go)

ONE test, `test/flux_vale/admin_authority_test.exs`, walking every
resource of every configured domain and demanding one of exactly two
states: **full** — the Arc 1 bypass AND the Arc 2 paper_trail block are
both present — or a **named exemption entry with its reason** (the six
machinery rows, plus interim pendings while the arcs build). A NEW
resource joining any `ash_domains` list fails the build until it is
deliberately added to a set: the doctrine survives resource growth, which
is the whole point of making it a gate rather than a convention. Phasing:
between A2-S1 and the closing slice, not-yet-rolled-out business
resources carry explicit `pending` exemption entries naming the slice
that resolves them (the test fails on any resource that is neither full,
exempted, nor pending); the closing slice asserts ZERO pendings remain.

## ARC 1 — authority (#644)

### Mechanism: the existing platform-admin check, one bypass per resource

Ash 3.37's policies doc names the exact idiom: a bypass policy is for "a
simple rule like 'an admin can do anything' without needing to specify it
as part of every other policy." Per-resource, first in the policies block:

```elixir
bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
  description("Platform admins see and do everything (#644)")
  authorize_if(always())
end
```

NO new role, NO new concept (owner correction, Nov 9): the blanket
authority attaches to the EXISTING platform admin — `platform_role ==
:admin` on User, the role the admin account already carries.
`FluxVale.Checks.ActorIsPlatformAdmin` stays exactly what it is (the
single answer to "is this actor a platform admin", predicate shared with
plug-land, used by today's read arms on Wallet/LedgerEntry/PAT/User —
untouched, byte-for-byte). The machine-API refusal rides the bypass as a
CONDITION, not inside the actor check: `FluxVale.Checks.CallOutsideMachineApi`
(new, `lib/flux_vale/checks/`, a call-property check — not actor-shaped
because it is not an actor question; the moduledoc says so) answers
"this call originates outside the machine API" (web console or any
non-PAT context). When the bypass passes, every other policy — including
the member filters — is skipped: platform-admin reads are cross-org by
construction, not by per-resource arms. The condition pair also means the
doctrine is surgically scoped: existing arms keep their exact semantics
(an admin PAT still passes today's arms exactly as today), and only the
NEW blanket is PAT-refused.

Why not the alternatives (D1): per-policy admin arms (the #577/#613/D2
pattern generalized) touch every policy on 29 resources, drift silently
when a new policy forgets the arm, and compose wrongly with
`forbid_unless`-shaped gates (the arm inside one policy cannot rescue a
`forbid_unless(member)` in it — each gate needs its own edit). Ash has no
domain-level policy layer in 3.37. A macro injecting the bypass hides the
doctrine from grep. A second actor-shaped "console admin" check forks the
platform-admin notion against the one-module-one-question rule (owner
correction killed the concept before it ever shipped). The bypass is the
documented idiom, is greppable, and one doctrine gate makes it complete.

### The role model: two tiers, both already in the schema

Platform admin — `PlatformRole :admin`, FluxVale as a whole, access to
everything (this doctrine). Organization admin — the org-scoped
`MembershipRole` axis: today that tier is `:owner` (provisioning creates
owners; `:member` is the expansion point), and a dedicated `:admin`
membership value is the natural future slot if owner/member proves too
coarse — decided when a concrete need lands, not now. The axes must never
be conflated (both type moduledocs already say so). The future scoped
roles sketch (below) is org admins getting console-shaped powers scoped
to their org — NOT a third tier and NOT a "console admin".

### The doctrine gate

Described above ("the business resource set" → "the doctrine gate"):
`test/flux_vale/admin_authority_test.exs` walks
`Application.get_env(:flux_vale, :ash_domains)`, asserts every
business-set resource's policies carry the condition-pair bypass
(`ActorIsPlatformAdmin` AND `CallOutsideMachineApi`) AND the paper_trail
block (Ash policy + extension introspection; probe the exact APIs first),
and that every other resource holds a named exemption with a reason. A
new resource fails CI until it joins a set — the decision is forced,
never silent. The bypass half of the gate goes live in this arc; the
trail half activates as A2's rollouts land (the pendings phasing above).

### Reads

Platform-admin reads through the bypass are unfiltered: every instance,
org, gateway, domain, wallet, ledger row, user, membership, invite,
topup, feedback row, catalog/pricing row, cross-org. This subsumes 595's
D2 arms (slice 5's seven Infrastructure read arms become
belt-and-suspenders — correct, leave them) and closes #613 (the gateways
section's operator-truth fields — `needs_attention_since`,
`token_set_at`, `dns_claims` — become policy-admitted). Members lose
nothing: the bypass condition never fires for them and every existing
policy applies verbatim.

### Writes

The same bypass admits platform admins on every action of the 29 —
including actions whose policies are `forbid_if(always())` system-only
gates (`Wallet :create`, `LedgerEntry :create`, machinery-adjacent
writes). This is deliberate (D4): the policy layer stops pretending an
operator class cannot do what `/admin/ash` already lets them do
`authorize?: false` (ADR-0027 Am. 1). What changes is reachability
honesty — nobody can call these action paths as an actor today except
through surfaces, and the surfaces stay curated: the console registry's
intent lists (machinery actions never render) and the curated sections
own what is OFFERED; the policies own what is PERMITTED. The machine API
is unaffected — its route table has no routes for system-only actions,
PAT actors never pass the bypass (below), and scope enforcement runs
before policies anyway.

The demotion-window seam is untouched and inherited: every console write
re-resolves the actor per event (#571/#617 ruling) and the bypass
evaluates the FRESH struct. A demoted admin's stale socket sees the
existing refusal copy.

### The blanket never rides a PAT in v1 (no god-mode PAT)

PAT actors never pass the bypass (`CallOutsideMachineApi` is false for
them), so an admin's PAT keeps exactly today's contract: scope-gated
routes, member-shaped policies — including today's per-resource admin
arms, which stay pure actor checks and keep their current behavior
byte-for-byte (the refusal lives on the bypass alone, the surgical
scoping D2 demands). The MCP router rides PATs too
(`conn.assigns.api_pat`), so MCP stays scope-bound. Webhooks and Oban run
actorless — policies never consult the bypass for them. Mechanism (D2):
`CallOutsideMachineApi` refuses calls whose Ash request context carries
the PAT marker (`FluxVale.Api.Scopes.pat_scopes_context_key/0` — the
`PutPatScopesInAshContext` bridge, written for every PAT call and absent
for every session call). Probe ladder for the worker, in order:

1. Does the policy check's context expose the Ash request context
   (`match?/3`'s second argument)? Read the marker there. Preferred — no
   new state.
2. If not: the two PAT boundaries (the `/api/v1` plug chain and the MCP
   router) additionally mark the process (process dictionary), which the
   check reads — actions run in the caller's process, and both boundaries
   are request processes.

Either way the pin is an integration test through the REAL boundary: an
admin's PAT with `instances:write` POSTing an instance for another org is
refused cross-org (policy forbids), while the same admin through the
console succeeds; a member-level PAT call on the admin's own org keeps
today's behavior. That test carries the fragility — a refactor that drops
the marker fails it loudly, not silently.

### Future scoped roles (sketched, not built)

The two-tier model above IS the role model: platform admin (everything,
this doctrine) and organization admin (org-scoped). The future sketch is
the ORG tier growing console-shaped powers: an org-admin grant resolver
answers "which of this resource's actions may an org admin of THIS org
run" (org-scoped variants of read/workflow gates), expressed as a second
condition set on the same policies — the platform bypass is untouched.
Whether the org tier is `:owner` or a dedicated `:admin` membership value
is decided when a concrete need lands. What is NOT sketched: a third
platform tier or any "console admin" concept — killed by the owner Nov 9,
before it ever shipped. The sketch lives in ADR-0047 so the shape is
recorded before it is needed.

### ADR-0047

`docs/adr/00047-platform-admin-authority.md`: the doctrine, the two-tier
role model, the bypass mechanism (existing platform-admin check + the
call-origin condition), the PAT refusal and its surgical scoping, the
surfacing-vs-permissioning split, the set table, the org-admin future
sketch, and what is rejected (per-policy arms, god-mode PATs, an API
admin scope, any console-admin tier). Lands with the first authority
slice.

## ARC 2 — audit (#645)

### Sweep: the business set (29 resources)

D5. Everything the admin console can mutate, plus identity and accounts,
plus the member/PAT-mutated surfaces the console never touches (org
creation, invites, PAT mints, feedback writes) — because the issue's
attribution demand covers PAT actors too, and the doctrine's premise is
"every mutation", not "every console mutation". The six machinery
resources stay out: versioning ephemeral rows (auth codes rotate in
minutes) is noise with secret-adjacent values, and versioning append-only
tables (snapshots, `Api.AuditEvent`) stores a trail of a trail. Uniformity
is served by the set being ONE list with ONE config block, not by
including everything.

### One config posture, verbatim on all 29

```elixir
paper_trail do
  primary_key_type :uuid_v7
  change_tracking_mode :changes_only
  store_action_name? true
  store_action_inputs? true
  sensitive_attributes :redact
  ignore_attributes [:created_at, :updated_at]
  reference_source? false
  create_version_on_destroy? true
  operation_id_field :operation_id
  mixin {FluxVale.PaperTrail.VersionMixin, :version_resource, []}
  belongs_to_actor :user, FluxVale.Identity.User,
    domain: FluxVale.Identity,
    on_delete: :nilify
end
```

This block is the COMPLETE copy-paste posture — the mixin line is not
optional (it carries the read policy, the indexes, and the actor label;
a resource omitting it ships policy-less version tables).

Rationale (D6): `:uuid_v7` matches ADR-0032; `:changes_only` keeps rows
compact and is atomic-safe (`:full_diff` is documented as not
atomic-trackable — probe `:full_diff` only if `:changes_only` proves
insufficient for the console view); `store_action_name?` +
`store_action_inputs?` give the audit view action and arguments (inputs
redact sensitive values); `sensitive_attributes :redact` records THAT a
sensitive attribute exists on the row, never the value — the blanket
posture since User/MembershipInvite/PAT rows carry sensitive attrs (the
0.8.1 quirk the hostile review surfaced: an unchanged sensitive attr
still lands as a REDACTED entry in `changes`, so the changes map can
overstate what moved on sensitive-bearing rows — A2-S3 probes a changed?
guard before those resources ship, and the ADR says so plainly);
`reference_source? false` is the audit-grade choice: version rows survive
the record's own destruction, so a destroy leaves its own evidence (a
cascade-delete trail is theater); `create_version_on_destroy? true` rides
it — no FK means the destroy-version insert succeeds (a destroy version's
own `changes` is empty — `:changes_only` has no deltas on destroy — the
final state reconstructs by replaying the record's chain, which the
proof tests assert);
`operation_id_field` correlates the multi-record writes one action causes
(goodwill credits, `set_tags`, bulk paths). `on_delete: :nilify` on the
actor reference: a user deletion (the data-deletion flow) keeps the
history and nils the attribution — the honest record, revisit when the
data-deletion policy finalizes. PA rider: before settling for nil, A2-S1
probes whether the version row can carry a cheap denormalized actor label
(the docs confirm the actor is always set on the version changeset — a
shared-mixin attribute + `on_create` change is the candidate shape) so
deleted actors' versions still answer WHO. Decision rule: if it costs
more than a line or two beyond the already-needed mixin, nil is accepted
— the slice report says which.

Migrations: `mix ash.codegen` per domain rollout — additive-only new
tables (ADR-0013), derived names (`wallets_versions` et al; module
`FluxVale.Billing.Wallet.Version`). No collisions exist today (grep
verified); the worker re-verifies at codegen. Domains gain the
`AshPaperTrail.Domain` extension with `include_versions? true` so
migrations and reads see the version resources.

### Actor attribution

`belongs_to_actor :user` answers WHO for both actor kinds — a PAT's actor
IS the User, and system writes (Oban, webhooks, seeds) carry no actor:
`nil` is the honest system attribution. The web-vs-PAT channel is NOT a
column in v1: every PAT call already writes a per-request
`Api.AuditEvent` row (token id, timestamp), and versions carry
`operation_id` — correlation, not duplication. Revisit trigger: if the
owner wants the channel on the row, the `paper_trail metadata` +
`context.paper_trail_metadata` seam is the mechanism, written from the
same two boundary plugs that would carry the PAT marker.

### Version read policy (D7, revised on hostile-review evidence)

The shared VersionMixin injects a DIRECT read policy on every version
resource: platform admins read, everyone else is forbidden —
`policy always() do authorize_if(FluxVale.Checks.ActorIsPlatformAdmin) end`.
Why not source-policy replay (`apply_can_read_policy?`): the hostile
review of PR #651 proved the replay makes version rows readable by
WHOEVER can read the source — including anonymous callers once
public-read sources (Feedback, Catalog, Pricing) get versioned — and it
filters out destroyed-source versions for admins too (an `exists()`
over a gone row cannot match any actor). The direct admin-only policy
fixes both: non-admins never read a trail row, and admins see orphaned
destroy-evidence. Members get no version reads in v1 (the audit view is
console-only; a member surface, if ever, is a deliberate future policy).
Implementation detail the worker probes: dropping
`apply_can_read_policy?` may drop the Policy authorizer from the
generated resource — the authorizer must attach (via `version_extensions`
if the DSL allows, else keep `apply_can_read_policy? true` AND the mixin
policy, accepting the orphan-filter quirk for the A2-S4 view to work
around). Two further recorded truths: ash_paper_trail's own version-
create bypass rides the caller-settable `ash_paper_trail?` context key
(same trust class as `authorize?: false` — internal discipline; the
audit view must never forward request-derived context), and AshAdmin's
`authorize?: false` mount CAN edit version rows directly (accepted
superuser capability, ADR-0048 records it — the doctrine attributes
mutations, it does not tamper-proof against the operator's own debug
mount).

### Retention and growth

Forever (D8). Friends-beta volumes make time-boxing premature; version
rows are compact diffs, not snapshots; and an audit trail with a janitor
is only an audit trail back to the janitor's horizon. The existing
janitor pattern (`prune_audit_events`, `prune_request_windows`) is the
ready shape if scale or the data-deletion policy ever demands a horizon —
that trigger is recorded in ADR-0048, not built. Growth/load notes for
the record: one extra insert per mutation inside the same transaction;
system-path ticks (instance lifecycle, backup runs) version with nil
actors — tens of instances make this noise; seeds version honestly (the
row was seeded at T — no `ash_paper_trail_disabled?` special-casing);
`only_when_changed?` default true keeps no-op updates from writing
versions. Indexes for the audit view (`version_source_id`, actor) ride
the first rollout via the version mixin; exact attribute names confirmed
at codegen.

### Console surfacing (LAST, its own slice)

A new "Audit" sidebar section: cross-resource version browsing over the
business set — filter by resource and actor, the shared DataTable pattern
(#643 when it lands; the engine's table chrome otherwise), a record's
history panel linked from show pages. Sequenced after the core trail per
the issue's own reading ("a natural follow-up slice once the trail
exists"). Version resources stay OUT of the generic console registry —
excluded by name with the reason "the audit trail surfaces here, not as
raw tables" — and the registry parity test is updated in the SAME slice
that first adds version resources to a live domain (the parity test walks
`Info.resources()` and would otherwise fail on them — this is the one
hard CI collision between the arcs and the 595 lane; it is handled, not
hit). AshAdmin may render version resources on `/admin/ash` — harmless
(trusted-superuser debug posture, Am. 1), zero work, accepted.

### ADR-0048

`docs/adr/00048-ash-paper-trail-audit.md`: the sweep set, the config
posture with rationale per line, attribution (user + nil-system +
correlation via AuditEvent), retention (forever + triggers), the read
policy, and the version-resource surfacing decisions. Lands with the
first audit slice.

## Decisions

- **D1 — authority mechanism**: per-resource `bypass` on the condition
  pair — the EXISTING `ActorIsPlatformAdmin` check plus
  `CallOutsideMachineApi` — + the doctrine gate in its strictest form
  (PA rider: any new resource joining an `ash_domains` list fails the
  build without bypass+trail or a named, reasoned exemption — the
  doctrine survives new resources being added). NO new role or concept
  (owner correction, Nov 9: the blanket attaches to the existing
  platform admin). REJECTED: per-policy admin arms (the #577/D2 pattern
  generalized — ceremony ×100+, drifts, cannot rescue `forbid_unless`
  gates); macro-injected bypasses (ungreppable); Ash domain-level
  policies (no such layer in 3.37); a "console admin" check/module
  (forks the platform-admin notion, and the concept is owner-dead).
- **D2 — the blanket never rides a PAT**: the refusal is a CONDITION on
  the bypass (`CallOutsideMachineApi`), leaving `ActorIsPlatformAdmin`
  and every existing arm byte-for-byte unchanged — the strictest reading
  of "PATs keep today's contract". API and MCP (both PAT-bound) see no
  new authority; webhooks and Oban are actorless. REJECTED: baking the
  refusal INTO `ActorIsPlatformAdmin` (silently narrows today's
  reachable admin-PAT behavior on wallet/ledger reads — a contract
  change nobody asked for); no refusal at all (silent god-mode PAT);
  boundary-side restrictions (would change today's member-level
  admin-PAT behavior).
- **D3 — the authority set**: the 29-resource business set (the shared
  table), excluded machinery named with reasons. REJECTED: all 35
  (bypasses on Token/AuthCode/DeviceCode/snapshots are ceremony with no
  surface); only-console-exposed (reads the doctrine as narrower than the
  owner wrote it — "sees everything").
- **D4 — writes posture**: one bypass covering ALL actions including
  system-only forbids; surfacing stays curated (registry intent lists,
  sections own OFFERED, policies own PERMITTED). REJECTED: bypass scoped
  to non-system actions (per-action ceremony again; unreachable paths
  stay unreachable — the API route table has no such routes). ADR-0047
  carries this as a FLAGGED deliberate judgment call under the owner's
  own doctrine (PA rider: relayed to Terence; a future reader must see
  it was a decision, not an oversight).
- **D5 — audit sweep**: the same 29. REJECTED: all 35 (noise on ephemeral
  rows, secret-adjacent values, trails of trails); console-mutable-only
  (misses PAT/member mutations the issue explicitly wants attributed).
- **D6 — version config**: one uniform block (above), `:changes_only`,
  action name + inputs stored, sensitive redacted, `reference_source?
  false` + destroy-versioned, actor nilified on user delete, uuid_v7,
  operation_id. REJECTED: `:snapshot` (row bloat); per-resource tuning
  (drift); cascade-deleted versions (destroys their own evidence).
- **D7 — version reads**: a DIRECT platform-admin-only read policy
  injected by the shared mixin on every version resource (revised on
  hostile-review evidence — source-policy replay leaks trails of
  public-read sources to anonymous callers and hides orphaned
  destroy-evidence from admins). REJECTED: policy-less version resources
  (a hole in authorization-on-by-default); `apply_can_read_policy?`
  source replay (the two failures above).
- **D8 — retention**: forever, revisit triggers recorded (cost/scale,
  data-deletion policy finalizing). REJECTED: time-boxed janitor now
  (premature at friends-beta volumes; weakens the audit premise).
  ADR-0048 carries this as a FLAGGED deliberate judgment call under the
  owner's own doctrine (PA rider: relayed to Terence, same as D4).
- **D9 — console surfacing**: a dedicated Audit section, versions
  excluded from the generic registry by name; AshAdmin rendering them
  accepted. REJECTED: versions as generic-registry resources (the audit
  trail is a cross-resource view, not 29 raw tables). PA rider: the
  registry-exclusion coordination is ONE heads-up prompt to the 595
  architect in the slice that first adds version resources (A2-S1) — a
  courtesy, no dependency either way.
- **D10 — sequencing**: A2-S1 (dep + Ops proof) → A1 (authority, two
  slices) → A2 rollouts → A2 audit view. Rationale: the dependency and
  config are de-risked first; the authority widening then lands with the
  trail machinery proven; the interim window (authority live, audit
  partial) is disclosed and never WORSE than today — AshAdmin's
  `authorize?: false` surface has never been audited, so every slice only
  narrows the unaudited surface. REJECTED: audit-complete-first (delays
  the owner's daily tool a full arc for a window that is not a
  regression); authority-first (widens before any trail exists).

## Slices

Worker rules (every slice): model `zai-coding-plan/glm-5.3`; hostile
review on Synthetic `syn:large:text`, fresh context, cross-host. Sibling
worktree off latest `main`, rebase before PR if `main` moved. PR to
`main`, no reviewers/assignees, body from a file referencing #644/#645
(`Closes` only on an arc's closing slice, judged against the issue's done-
when). PR format: each paragraph one unbroken line; screenshot index table
with images beneath where the change is visual; conventional-commit
titles. Push/PR/merge UNGATED once the arc's slices are green (`cd
apps/platform && mix ci`), spec-true, and hostile findings adopted or
rebutted in-thread. Machine-load discipline: isolated DB partition
(`MIX_TEST_PARTITION`), reduced parallelism for heavy suites.
Schema-affecting slices regenerate `priv/open_api.json` (expected NO diff
— no new routes; a diff means something leaked into the router and IS the
finding) and `cargo check` in `crates/`. Copy: no em-dashes, no
semicolons, no ops IDs/agents/automation mentions anywhere public. No
attribution footers. Screenshots light + dark per the repo convention.

### A2-S1 — the trail, proven on Ops (first PR of the doctrine)

Dep pin (`{:ash_paper_trail, "0.8.1"}` — exact pin, `.formatter.exs`
import_deps), `AshPaperTrail.Domain` on the domains as they gain
versioned resources (Ops here), the config block on FeatureFlag +
AccessRule, codegen migrations, the registry parity-test update
(FeatureFlag.Version / AccessRule.Version excluded by name with the Audit
section as the reason), the version mixin (indexes), and the proof tests:
create/update/destroy each produce attributed version rows (admin actor
named; member actor named; system `authorize?: false` call → nil actor);
a destroy's version survives its record; sensitive attrs redact; inputs
stored. The actor-label tombstone probe (D6 rider) runs here and its
outcome is stated in the PR body. ADR-0048 (with D8's flagging) + this
plan doc ship in this PR. The architect sends the 595 heads-up prompt
(D9 rider) the moment this slice adds version resources. OpenAPI regen
no-diff verified. Done when: `mix ci` green and the trail is provably
attributed on Ops.

### A1-S1 — the bypass, the doctrine gate (the authority PR)

`FluxVale.Checks.CallOutsideMachineApi` (probe ladder for the context
marker FIRST; the boundary integration pin second) — `ActorIsPlatformAdmin`
stays untouched — the condition-pair bypass on all 29 business-set
resources (replacing User's and Cluster's existing blanket admin
policies, which the bypass subsumes), the doctrine gate (bypass half
live; trail pendings for the resources A2 has not reached yet — the
gate's phasing per D1's rider), policy tests per the probe table
(platform admin cross-org read/write true; member scoping byte-identical
— the existing suites ARE the regression net), the PAT refusal pin,
ADR-0047 (with D4's flagging). No console copy changes here (surfaces
follow). Done when: a platform-admin actor passes cross-org in policy
tests, a PAT actor does not, members are unchanged, and the doctrine
gate forces every future resource to decide.

### A1-S2 — the console reads cross-org (the visual PR)

The gateways section gains #613's operator-truth fields; the orgs section
drops its scoped-stitching copy where real reads now flow; the people
surface and the engine indexes simply BECOME cross-org (the bypass did
it) — copy updated where it promised member scope, scope notes removed
where they warned. Screenshots per surface, light + dark. Done when: the
console shows every business resource cross-org with honest copy.

### A2-S2 — rollout: Billing, Pricing, Catalog, Feedback (13 resources)

The config block + codegen + per-resource-class proof tests (money:
goodwill/waiver/topup lifecycles attributed; catalog: composite attrs
version as JSON in `changes`; feedback: moderation writes attributed).
Registry parity-test arms extended as domains gain version resources.

### A2-S3 — rollout: Infrastructure, Identity, Accounts (14 resources)

The high-churn one: instance lifecycle and gateway state machinery
version with nil actors (system paths) — assert honest system
attribution; org creation, invites, PAT mint/revoke attribute to their
actors; user rename/set_username attributes. Machine-load discipline
applies (this suite is the heavy one).

### A2-S4 — the Audit section (closing slice, `Closes #645` with A1-S1's
`Closes #644` already landed)

The sidebar section, cross-resource browsing (resource + actor filters),
per-record history from show pages, DataTable pattern, version-read
policy verified through the real console mount (admin sees all incl.
destroyed records' trails; a member mount attempt bounces at the gate).
The doctrine gate drops to ZERO pendings — every business resource full
(bypass + trail) or exempted by name, and the test refuses new pendings
from here on. Screenshots light + dark. Done when: every mutation on the
business set is attributable from the console — the doctrine's done-when.

## Risks

- **The PAT-marker probe fails both rungs** (check context closed,
  process marker unusable): fallback is minting-time — the bypass would
  then be actor-only and the API boundary must instead deny admin actors
  scope-granted cross-org writes explicitly. Structural change → PA
  relay before building. Judged unlikely (Ash.PlugHelpers context is
  request-scoped by design; the process rung is trivial).
- **Version-read authorizer attachment**: dropping
  `apply_can_read_policy?` may drop the Policy authorizer from generated
  version resources — the worker probes attaching it via
  `version_extensions`; if impossible, `apply_can_read_policy? true`
  stays alongside the mixin policy and A2-S4 works around the
  orphan-filter quirk (both postures close the anonymous-read hole).
- **Atomic updates under `:changes_only`**: supported per the docs;
  `:full_diff` is the known non-atomic mode — not chosen. Probe
  atomic-update actions (resize) in A2-S3.
- **Volume from system paths** (instance settle ticks, gateway
  observers): nil-actor version rows at beta scale are noise; triggers
  recorded in ADR-0048. `only_when_changed?` default absorbs no-ops.
- **Parity-test collisions with the 595 lane** (version resources join
  live domains while slices 3-6 fly): the exclusion-by-name arms land in
  the SAME slice that adds the first version resources (A2-S1, Ops is
  already live); rebase discipline per the lane's own rule.
- **Migration weight**: 29 new tables across the rollout slices, all
  additive; `ash.codegen --check` gates drift as always.
- **Upgrades**: exact-pinned 0.8.1; bumps are deliberate diffs (repo
  rule).

## Appendix — evidence (2026-11-09, worktree at 8511599e)

Policy census across the 35 (grep, the arms' shapes):

- Blanket admin policies today: User ("Platform admins manage users"),
  Cluster, FeatureFlag/AccessRule (Ops domain posture), — the bypass
  generalizes these.
- In-policy admin arms (the #140/#571/D2 shape): Wallet + LedgerEntry
  reads, PersonalAccessToken read/create, Organization `:admin_lookup`
  (action-scoped), User `:set_username`.
- Member-scoped with NO admin arm (the #644 widening set): Organization
  primary read, Membership read, MembershipInvite read, Topup read,
  UserEmail read, the seven Infrastructure reads (595 slice 5's D2
  territory — subsumed, not reverted).
- System-only forbids the bypass now admits for admins (surfacing
  unchanged): Wallet `:create`/`set_carryover`/`set_ladder_state`,
  LedgerEntry `:create`, Membership `:create`/`destroy`, Topup
  create/update, InstanceAllocationSnapshot all (stays excluded — no
  bypass, no versioning).

Console seams verified: the engine's write path re-resolves the actor per
event and passes the fresh struct (`action_opts: [actor: admin]`, #617);
`AdminConsole.visible?/3` flips true for admins wherever the bypass
admits, with the registry intent lists still hiding machinery; the
registry parity test asserts `Info.resources()` equality per live domain
(the version-resource collision A2-S1 handles). `Api.Scopes` route table:
no admin scope, no system-action routes — PAT reachability unchanged by
D4. MCP authenticates via PAT (`conn.assigns.api_pat`). The OpenAPI
artifact renders from the router (`AshJsonApi.OpenApi.spec`), not from
domain resource enumeration — no routes added, no diff expected.
ash_paper_trail 0.8.1 DSL verified against hexdocs (options, destroy
handling, actor refs, metadata, operation_id) on 2026-11-09.
