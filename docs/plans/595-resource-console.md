# Plan: the generic resource console (#595)

Status: ACCEPTED — Terence's go relayed by the PA, 2026-11-08. The
four decisions below are settled; slices dispatch in order. Architect
worktree `fv-resourceconsole`, branch `feat/resource-console`. This
document is the implementation contract for every slice; a worker
implementing any slice reads THIS FILE IN FULL (slices reference the
contracts above them, they do not restate them).

The deciding record is [ADR-0027](../adr/00027-admin-surface-ashadmin.md)
(Am. 3 keeps AshAdmin at `/admin/ash` as the emergency surgery surface).
Issue: fluxvale/fluxvale#595. This plan, once accepted, is the source
for ADR-0027's next amendment at parity time (slice 7).

## What is being built

A generic resource console: CRUD over the AshAdmin-exposed resource
set, driven by the resource definitions, styled like the console
(#583 sidebar shell). It replaces AshAdmin's daily use and eventually
AshAdmin itself. Three properties, in priority order:

1. **Policy-enforcing** — every read and write runs with the operator
   as actor and authorization ON. This is the deliberate contrast with
   AshAdmin, which runs `authorize?: false` (ADR-0027 Am. 1: a trusted
   superuser surface). Actions surface only when the operator may run
   them.
2. **Definition-driven** — no per-resource hand-written pages. Tables,
   record pages, and forms are introspected from
   `Ash.Resource.Info`/action accept lists. The only hand-maintained
   part is the exposure registry (below), which is the security
   boundary, not a page generator.
3. **Native to the console** — same shell, same components
   (`.card`, `.input`, `.button`, `.badge`, `.empty_state`,
   `confirm_block`), same type system, full-bleed content per #593.

## Decisions settled (Terence, 2026-11-08)

- **D1 — CONFIRMED: the exposure set.** The console covers the same
  six domains AshAdmin shows today (ADR-0027 §3 opt-in): Ops, Catalog,
  Infrastructure, Pricing, Billing (wallet + ledger only), Feedback —
  23 resources (Ops 2, Catalog 3, Infrastructure 9, Pricing 2, Billing 2, Feedback 5). Identity, Accounts, and Api stay out. The issue's
  "ALL resources" reads as "every resource of the exposed domains".
  Widening (Api's audit events, say) is a later one-line registry
  change plus a sanity pass.
- **D2 — APPROVED: platform-admin read arms.** All seven
  member-scoped Infrastructure reads (Instance, BackupSetting,
  BackupRun, AccessGateway, AccessRoute, AccessDomain,
  InstanceHostname) gain `authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)`
  arms in slice 5 — as BUILT policy, not intent. Row-hiding remains a
  D2-class concern only where read arms are not granted: nowhere in
  the registry once slice 5 lands. Any future member-scoped resource
  added to the registry carries its arm decision at intake (the
  registry parity test forces the intake).
- **D3 — REVISED 2026-11-08 (Terence): domain-divided navigation.**
  The console does not navigate through one flat everything-page: the
  MAIN sidebar rail carries a "Resources" group whose collapsible
  domain sub-groups (plain `<details>/<summary>`, collapsed by
  default, the active domain's group open) hold every live registry
  resource as a leaf link — the registry drives the nav, pending
  domains render nothing until their slice. The `/admin/resources`
  landing stays as the group's link target and the honest bounce
  destination: an overview, never the only path. (Supersedes the
  original one-entry ruling; the architect's call within Terence's
  latitude put the grouping in the main rail, not an in-section one.)
- **D4 — SETTLED: clean removal, no flag.** Slice 8 deletes route,
  dep, and `admin do` blocks in one PR. That PR keeps Terence's
  explicit sign-off gate: it is prepared, shown to him, and merged
  only on his word.

## Engine design

### Exposure registry — `FluxValeWeb.AdminConsole`

New module `lib/flux_vale_web/admin_console.ex`. It is the ONLY
hand-maintained surface and the security boundary (the ADR-0027 §3
opt-in posture, now console-owned instead of ash_admin-owned):

```elixir
domains()          # [%{key: :ops, label: "Ops", module: FluxVale.Ops}] in display order
resources(key)     # [%{key: :feature_flag, module: ..., config: %{...}}] for one domain
fetch(domain_key, resource_key)
                   # {:ok, %{domain: ..., module: ..., config: %{...}}} | :error
visible?(actor, resource_module, action_name)
                   # boolean — Ash.can?({resource, action}, actor), maybe_is: true
```

- Domain/resource URL segments resolve ONLY against registry atoms
  (map lookup over existing atoms; never `String.to_atom` on input).
  Unknown segments 404 (a LiveView `raise`/redirect per the surface's
  existing unknown-page posture — match what other admin surfaces do).
- Per-resource `config` (all optional, `:auto` defaults):
  `label` (display name), `note` (honest copy shown on the resource's
  index — the FLAG mechanism, e.g. "Writes are system-only"),
  `columns` (index columns; `:auto` = label-ish attr plus the next
  public attrs, capped, with `created_at` pinned — the pinned stamp
  and any configured column resolve ONLY against public attributes
  and the DECLARED framework timestamps, never a find over all
  attributes), `label_attr`
  (row-label heuristic override; auto order: `name`, `title`, `email`,
  `key`, `slug`, else short id), `create_actions`/`update_actions`/
  `destroy_actions` (exclusion lists for machinery actions — Intent,
  see "action visibility"), `excluded` (per-domain resource exclusions,
  each documented: Billing excludes Topup).
- A registry parity test walks
  `Application.get_env(:flux_vale, :ash_domains)` and fails when a
  domain or resource exists that the registry neither includes nor
  explicitly excludes by name — new resources force a decision, the
  "flagged, not force-fitted" discipline enforced by CI.

### Action visibility (the policy contract)

Two independent gates, both required:

1. **Registry intent** — machinery actions never render. Instance's
   `perform_*`/`mark_*`/`settle_anchors`, AccessGateway's
   `perform_*`/`mark_*`/`update_state`/`set_api_token_ref`/
   `update_claims`/`destroy_after_teardown`, BackupRun's
   create/update, InstanceHostname's `mint`, InstanceAllocationSnapshot
   is read-only-note, LedgerEntry's `create` (only `grant_goodwill`
   creates). Curated per slice from the enumeration (appendix A).
2. **Actor truth at render** — `AdminConsole.visible?/3` (backed by
   `Ash.can?`, `maybe_is: true`). `false` hides the control (verified
   probe results: platform admin on `Wallet :create` → false, on
   `LedgerEntry :create` → false, on `FeatureFlag :create` → true).
   `:maybe` renders the control and the dispatch refuses honestly
   with an error flash — the policy stays the authority, the UI never
   pre-computes data-dependent answers.

Every write handler re-resolves the actor from the session
(`FluxValeWeb.UserAuth.resolve_user/1`, which also checks token
revocation) and requires the platform-admin role on the FRESH struct —
the #571 demotion-window ruling; the mount-resolved struct is never
trusted for writes. If #571 merged a shared helper for this by the
time a slice starts, reuse it verbatim.

Reads: `Ash.Query.for_read(resource, primary_read)` with
`actor: admin`, `Ash.read!` (repo default: authorize ON), loaded
belongs_to relationships for link labels. Pagination: offset pages on
the primary read — every exposed read action is `countable: true,
offset?: true, max_page_size: 250` (verified, appendix A); page size
25, `page: [limit: 25, offset: n, count: true]`, page numbers from
count. Default sort `created_at: :desc` where the resource has it.

### Routes — inside the existing `:admin` live_session

```elixir
live("/admin/resources", FluxValeWeb.AdminLive.Resources, :domains)
live("/admin/resources/:domain", FluxValeWeb.AdminLive.Resources, :domain)
# "new" is literal BEFORE the :id route below — the /organizations/new
# idiom; ids are UUIDs and can never be "new".
live("/admin/resources/:domain/:resource/new", FluxValeWeb.AdminLive.Resources, :new)
live("/admin/resources/:domain/:resource", FluxValeWeb.AdminLive.Resources, :index)
live("/admin/resources/:domain/:resource/:id/edit", FluxValeWeb.AdminLive.Resources, :edit)
live("/admin/resources/:domain/:resource/:id", FluxValeWeb.AdminLive.Resources, :show)
```

One LiveView module (`lib/flux_vale_web/live/admin_live/resources.ex`),
one live action per surface, same mount shape as the other admin
LiveViews (`Layouts.app ... bare`, `appgram contents`, band + wrap,
`AdminShell.sidebar current="resources"` — `exact: false` on
sub-routes per the section idiom). The query param `?action=<name>`
selects among multiple create/update actions (default: the primary).
`?page=N` paginates. The routes live in the live_session block, which
already precedes the `ash_admin` wildcard — keep them there.

### Rendering — `lib/flux_vale_web/components/admin_resource.ex`

Type-driven value rendering, one clause per shape (all through
gettext; NO em-dashes or semicolons in any user-facing string):

| Shape | Index cell | Show page |
|---|---|---|
| UUID/UUIDv7 | first 8 chars, mono, full value in `title` | mono, full, copyable text |
| belongs_to → registry resource | loaded record's label, link to its show page | link |
| belongs_to → outside registry (orgs, users) | short UUID, `title` full | short UUID (org labels are #571's scoped seam — NOT reused here) |
| string/ci_string | truncated text, `title` full | full text |
| integer/decimal | right-aligned mono | mono |
| boolean | Yes/No | Yes/No |
| UTC datetime (any precision) | `%b %d, %Y` (the people surface's `stamp_text` shape) | date + `%H:%M` UTC, `title` full |
| atom/custom enum (one_of / Ash.Type.Enum) | humanized text in a neutral `.badge` | badge |
| map/custom struct | type name + "view" link to the show anchor | `<details>` block, pretty JSON/inspect, mono `pre` |
| {:array, _} | count | comma list |

Index table: the console's existing table grammar (grid or table rows,
`overflow-x-auto` with a measured `min-w`, header row uppercase xs,
rows hover-tinted — match the people/billing surfaces exactly).
Record show: definition list of ALL public attributes in declaration
order, actions bar (per-action buttons per visibility), destructive
actions behind `confirm_block` (the shared `destructive-confirm`
testid). Empty states via `.empty_state`. A note banner renders
`config.note` when set. Registry-authored note and label strings are
config, not template literals — static gettext extraction cannot see
them, so if the console ever localizes they need a RUNTIME gettext
path (lookup at render), not extraction.

Column selection UI is OUT of scope (the issue's "where cheap" — the
curated `columns` config plus the show page covers it). Search is OUT
of scope for v1 (flagged; AshAdmin parity does not require it).

### Forms — `AshPhoenix.Form` (dep already present, verified)

`AshPhoenix.Form.for_create(resource, action, actor: fresh_admin)` /
`for_update(record, action, ...)`; `to_form` into `<.form>`; the
imported `<.input>` renders every field. Input mapping: string /
ci_string → text; integer → number; decimal → number `step="0.01"`;
boolean → checkbox; enum → select from one_of constraints (atom one_of
or `Ash.Type.Enum` — `Ash.Type.Enum.values/1`); uuid FK → text input
labeled by the relationship; map/custom struct → JSON textarea
(engine JSON-decodes to a map before the form; a cast failure renders
as a field error); arrays only where the registry includes them
(none today). Required-ness from `allow_nil?`. Per-field errors ride
AshPhoenix's form data protocol into `<.input>`; top-level failures
flash the honest one-liner (match the people surface's refusal-copy
register: what was refused, what to do).

Named create/update actions (Wallet `:set_waiver`, LedgerEntry
`:grant_goodwill`, Feedback Post `:set_status`/`:set_tags`, ...) are
just more forms over the same machinery — the action picker is a
query param, the forms are generated per action's accept list.

### What is explicitly NOT in the engine

Generic (non-CRUD) actions (`:action` type), relationship management
UIs (manage_related), actor impersonation, search, column selection,
CSV export, Identity/Accounts/Api domains. Each is a later slice if a
concrete need lands; none is AshAdmin parity for THIS operator set.

## Slices

Worker rules (every slice): pin model `zai-coding-plan/glm-5.3`.
Sibling worktree off latest `main`, PR to main (reference #595 in the
body; `Closes #595` only on the final parity slice). `cd
apps/platform && mix ci` green (coverage 100% by exclusion, credo
strict, `MIX_ENV=test mix gettext.extract` when copy changes).
Screenshots in the PR body as ABSOLUTE head-branch raw URLs, light
AND dark, from the seeded local stack, under
`docs/screenshots/<pr>/`; GIF when the slice ships motion. Rebase
before PR when `main` moved. Hostile fresh-context review on Synthetic
`syn:large:text` per the standard arc. Copy: no em-dashes, no
semicolons, no ops-ticket/agent/automation mentions anywhere public.
PR bodies carry NO hard wordwrap: each paragraph is ONE unbroken line
(GitHub wraps it; 80-column prose renders as ragged blocks), tables
and code blocks excepted. A body that embeds screenshots opens with a
table indexing them (capture name, what it shows), the embeds directly
beneath. Read the platform AGENTS.md toolchain recipes before
scaffolding.

### Slice 1 — engine read path, proven on Ops

Build the registry, routes, and read surfaces; prove them on
`FluxVale.Ops` (FeatureFlag: 5 public attrs, no relationships,
blanket platform-admin policy; AccessRule: ci_string attrs + a `purpose`
atom enum, same policy — the two simplest resources that exist).

- `FluxValeWeb.AdminConsole` with Ops configured (AccessRule columns
  auto; FeatureFlag columns auto) + the registry parity test (all 9
  configured domains must appear: 6 included, Identity/Accounts/Api
  excluded BY NAME with the comment why).
- All four read routes only (`:domains`, `:domain`, `:index`, `:show`);
  the `:new`/`:edit` routes arrive in slice 2 with their mounts — no
  dead routes, no placeholder mounts.
- Typed value rendering for the shapes Ops exercises: uuid, string,
  boolean, integer, atom enum (AccessRule `purpose` → badge),
  timestamps, ci_string (AccessRule — renders as text, no case games).
  The unknown-type fallback (inspect in mono) must exist and be
  tested — later slices lean on it.
- Pagination (25/page, count-aware controls, prev/next + page
  numbers, honest "no rows" empty state).
- Sidebar: new group + entry per D3; the shell's component-contract
  test updated.
- Tests: registry parity; route resolution (unknown domain/resource
  404s); index renders rows with typed cells; show renders all
  public attrs; pagination math; non-admin conn bounced by the route
  gate AND non-admin live mount bounced by `AdminGate` (both arms);
  rendering is actor-safe (no non-public attribute ever appears —
  assert the set of rendered field names equals the public set).
- Screenshots: domains overview, Ops domain page, both index tables,
  one show page — light and dark.

Done when: an operator can browse Ops flags and access rules with
pagination and read every public field, styled like the people
surface, CI green, and the parity test would fail on any new
undecided resource.

### Slice 2 — engine write path, proven on Ops

The generic create/update/destroy machinery on the same two
resources (both full CRUD by policy — the cleanest possible proof).

- `:new`/`:edit` mounts over `AshPhoenix.Form` (create `:create`,
  update `:update`, destroy `:destroy`); the `?action=` selector
  machinery (Ops has one action each, but build the selector — later
  slices need it).
- Input mapping per the contracts table (Ops exercises text, number,
  checkbox, enum select — the enum select is AccessRule `purpose`).
- Validation: per-field errors via `<.input>`, constraint failures
  (FeatureFlag `key` regex, `rollout_percentage` 0..100) render
  inline; success navigates to the record's show page.
- Destroy: `confirm_block` on the show page (title names the record
  by label attr, body states irreversibility), `phx-disable-with`
  fencing, double-click guarded (quiet expired arm), success returns
  to the index with a flash.
- Action visibility: `visible?/3` gates every button; the actions bar
  shows NOTHING when no action is permitted. Per-event actor
  re-resolution on every write (the #571 ruling) — the demoted-admin
  click test pins it.
- The policy-enforcement test the issue demands: a test acting as a
  NON-privileged user (regular `user!` fixture) asserts (a) both
  gates bounce, and (b) `visible?/3` hides every write action for
  that actor; plus the admin-on-system-only arm — build a Wallet
  assertion now (module-level `Ash.can?` probe is enough) or defer it
  to slice 3 where Wallet is in the registry — defer, note it.
- GIF: the confirm-then-destroy motion (light and dark).
- Screenshots: the create form, the edit form with an inline
  validation error, the confirm block — light and dark.

Done when: an operator can create, edit, and destroy Ops flags and
access rules through the console, policies refusing writes render
honestly, and a non-privileged actor gets no surface and no actions.

### Slice 3 — Pricing + Billing rollout (sanity pass 1)

Registry gains Pricing (Size, TaxRate — full CRUD) and Billing
(Wallet, LedgerEntry — the constrained set). New rendering shapes:
Decimal (Size `cpu_cores` — right mono, no currency inference),
enum badges (EntryReason, EntryType), `utc_datetime_usec`
(TaxRate validity stamps).

- Wallet: read + `:set_waiver` only (create is system-only —
  `visible?` proves it: the probe shows admin=false; assert it).
  LedgerEntry: read + `:grant_goodwill` only (same proof for
  `:create`). Billing config excludes Topup with the documented
  reason, via the registry's excluded-resources mechanism this slice
  introduces (per-domain, by name, each with its reason); the parity
  test then enforces it — a live domain's resources must each be
  included or excluded, never undecided. The registry `note` copy
  explains each constraint.
- These tables duplicate nothing the curated #571 surface owns —
  this is the raw generic parity surface; the curated surface stays
  the daily tool. Note this in the resource `note` copy.
- Money-adjacent fields stay raw integers/decimals — NO currency
  formatting in the generic engine (BillingComponents owns that
  grammar; the generic engine does not guess currencies).
- Sanity pass output: a short section in the PR body listing every
  resource checked (can? probe table for admin across all its
  actions), anything flagged and why.
- Screenshots: both domains' indexes, wallet show (waiver form),
  ledger show (goodwill form with confirm) — light and dark.

Done when: Pricing and Billing resources are browsable and every
policy-permitted write runs from the console; system-only actions are
absent, not present-and-failing; the sanity table is in the PR body.

### Slice 4 — Catalog rollout (sanity pass 2)

Registry gains Category, App, AppVersion (full CRUD, public reads,
admin writes). New shapes: in-registry FK links (App→Category,
AppVersion→App, AppVersion→recommended_size→Pricing.Size), the first
map-typed attrs (AppVersion env-var schema, first-run contract).

- FK link labels come from the loaded relationship (label heuristic).
- Custom composite types: show page renders them as read-only JSON
  `<details>`; forms render JSON textareas. If either composite
  refuses JSON-map casting, do NOT force it: exclude the attributes
  from the form via the registry (documented in `note`) and FLAG it
  in the PR body for a follow-up — that is the flagged-not-forced
  rule in action.
- AppVersion is the odd one (19 attrs): `columns` config trims the
  index to the readable set (slug/app/state-ish stamps/created_at);
  the show page keeps everything.
- The curated catalog surgery surfaces (#540) stay the daily tool;
  `note` copy says so. Sanity pass table in the PR body.
- Screenshots: app index (FK labels visible), app show, version form
  — light and dark.

Done when: the catalog tree is browsable with linked FKs, version
blueprints are editable where the type system allows, and every
composite-type refusal is flagged rather than forced.

### Slice 5 — Infrastructure rollout (sanity pass 3, the policy slice)

Registry gains all nine resources. THIS slice carries D2: add
`authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)` arms to the
member-scoped read policies of Instance, BackupSetting, BackupRun,
AccessGateway, AccessRoute, AccessDomain, InstanceHostname — one
comment per arm naming the console (not this plan) as the trigger and
the members-first semantics preserved. Each arm gets policy tests:
admin reads other-org rows, member scoping unchanged, non-admin still
denied.

- Action curation per the registry intent lists in the design
  section (Instance/AccessGateway machinery actions never render —
  belt: registry; suspenders: `visible?` is mostly false on them
  anyway).
- InstanceAllocationSnapshot: 1 public attr — `columns` = id +
  created_at, `note` copy says telemetry, read-only (its actions are
  system paths). This is the flagship flagged-not-force-fitted case.
- Instance index `columns`: org short UUID, name, app_version link,
  status badge, exposure, cluster, created_at — the
  `admin do table_columns` values that exist today seed the config
  (they die with AshAdmin in slice 8; the registry owns the values
  from here on).
- New shapes: `{:array, _}` (none here — skip clause), state-machine
  enums as badges (InstanceStatus via `status_badge`'s existing
  grammar — reuse the component, do not fork it), Map attr
  (Instance exposure) as read-only JSON details (form side: registry
  note, flagged).
- Sanity pass table across all nine (this is the one where it
  matters). Screenshots: instance index + show, gateway index,
  snapshot index (the flagged one) — light and dark.

Done when: every Infrastructure resource is reachable and readable
for a non-member platform admin, all operator-legal writes run,
machinery actions are absent, and the sanity table is in the PR body.

### Slice 6 — Feedback rollout (sanity pass 4)

Registry gains Post, Vote, Comment, Tag, PostTag. Public reads; the
paying-gate creates (admins pass), moderation updates (`set_status`,
`set_tags`), admin destroys. Comment create is any-authed — the
console runs it as the ADMIN actor (the console never acts as anyone
else; no impersonation in v1). Vote `cast`/`retract` as admin.
PostTag write paths flagged (`note` points at Post `:set_tags` as the
curated path). Many-to-many (Post tags) renders read-only as badge
list; no relationship-management UI. Sanity table. Screenshots: post
index, post show with tags, moderation form — light and dark.

Done when: the feedback data is fully browsable and every
moderation action the #592 surface does not already own runs here
too, with the sanity table in the PR body.

### Slice 7 — parity review + ADR amendment

No new surface. A review PR (docs-only plus any small copy/config
fixes it uncovers):

- Walk the parity checklist (below) per domain against live AshAdmin
  and the new console; record the result table in the PR body and in
  ADR-0027 as Am. 5 (the replacement record: what the console covers,
  the D2 read-arm decision, the residual AshAdmin demotion).
- Per-domain screenshot sets (light + dark) embedded — the issue's
  acceptance asks for them; the review PR is where the complete set
  lives in one place.
- Anything operators rely on that is missing lands HERE as small
  fixes, or is explicitly listed as accepted loss with your sign-off.

Done when: the checklist table is complete, every gap is either fixed
or accepted in writing, and ADR-0027 Am. 5 records the decision.

### Slice 8 — AshAdmin removal (needs Terence's explicit go)

Clean removal per D4: delete the `/admin/ash` route + `ash_admin`
router import, the dep and its lock entries, every `admin do` block
(domains AND resources — the registry owns all curated values since
slices 3-6 migrated them), the config.exs ash_domains comment updates,
and the AdminShell deep-debugging group copy (AshAdmin entry gone,
LiveDashboard stays; the group copy no longer says "tools" plural if
that reads wrong). ADR-0027 Am. 5's removal clause flips to executed
(or this PR appends Am. 6 if slice 7 already merged). The router's
ORDER-MATTERS comment about ash_admin dies with the route; keep
LiveDashboard's own ordering note intact. Screenshot: the sidebar
without the entry.

Done when: `ash_admin` appears nowhere in the repo, `mix ci` green,
the operator (Terence) has signed off on the checklist, and the
debug group still links LiveDashboard.

## Parity criteria (slice 7's checklist)

For EVERY resource AshAdmin shows today (the 23 in appendix A):

1. Reachable at a stable URL, grouped by its domain.
2. Readable: every public attribute renders human-readable; the ONLY
   non-public values ever rendered are the framework timestamps
   (created_at/updated_at), sourced exclusively from the resource's
   create_timestamp/update_timestamp declarations — audit metadata,
   never business attributes. AshAdmin ignores `public?` entirely and
   renders non-public columns as table data, including credential
   references (ADR-0027 Am. 1); this surface does not (the parity bar
   is operator USAGE, and operators read values, not visibility
   flags).
3. Every action a platform admin can run through AshAdmin today
   (the can?-true set in the sanity tables) is runnable here, with
   policy enforcement ON (the deliberate difference, recorded).
4. Destructive actions confirm; failures read honestly.
5. Pagination replaces AshAdmin's unbounded lists (accepted
   difference; AshAdmin paginates too at 250).
6. Browsing works at operator widths, light and dark.

Known accepted deltas, pre-recorded: no authorizing toggle (we
ENFORCE instead), no non-public columns, no generic-action runner,
no relationship editor, no actor impersonation (§4's stance holds).

## AshAdmin removal proposal

Clean removal (D4), one PR, after slice 7's signed checklist. The
route leaves with the dep; no flag. Interim posture until then:
AshAdmin stays mounted and untouched at `/admin/ash` — the console is
additive the whole way, and any operator can fall back mid-rollout.
If a parity gap surfaces late, the fallback already exists.

## Risks

- **D2 read arms widen operator visibility** — deliberate, but it is
  the one policy-semantics change in the plan; blocked on Terence.
- **Filter-shaped policies mask scope** — a member-scoped table
  without its arm reads as "no rows", not "refused". Mitigation: the
  sanity tables probe `Ash.can?` per action and the read arms land
  in slice 5 with tests. Residual: any FUTURE member-scoped resource
  added to the registry without an arm would silently scope — the
  sanity-pass discipline (probe every resource at intake) is the
  guard; the registry parity test forces the intake.
- **Composite types in forms** (AppVersion env schema, first-run
  contract, Instance exposure map) may refuse JSON-map casting —
  flagged-not-forced rule applies; the fallback is read-only + note.
- **Registry drift from AshAdmin's curated config** — AshAdmin's
  `table_columns`/action lists die in slice 8; slices 3-6 must COPY
  their values into the registry as they pass (each slice's sanity
  table verifies nothing was left behind).
- **#593 layout in flight** — slices inherit the flush-sidebar /
  full-width frame; rebase before PR; table `min-w` values need
  #593's widths, not the pre-fix centered band.
- **maybe-buttons** — controls rendered on `:maybe` can refuse at
  dispatch (member-gated actions). Honest by design; copy must say
  refused, not error.
- **Scope creep into generic actions** — the machinery actions are
  genuinely useful (deploy, suspend) but they are WORKFLOW surface
  (the "orgs and instances" section owns them), not generic CRUD.
  The registry exclusion lists are the pressure valve; resist adding
  a generic-action runner unless Terence asks.
- **Volume** — offset pagination on unbounded reads at 25/page is
  fine at beta scale; revisit at InstanceAllocationSnapshot scale
  (it grows per settle tick — keyset pagination later if it bites).

## Appendix A — enumeration evidence

Transcript of the live enumeration (`MIX_ENV=test mix run` over the
compiled resources, 2026-11-08, worktree at origin/main 081c0f1f).
Configured domains: 9. AshAdmin-exposed (`admin show? true`): 6.

| Domain | admin show? | Resources (in-registry / excluded) |
|---|---|---|
| FluxVale.Ops | yes | FeatureFlag, AccessRule |
| FluxVale.Catalog | yes | Category, App, AppVersion |
| FluxVale.Infrastructure | yes | Cluster, Instance, InstanceAllocationSnapshot, BackupSetting, BackupRun, AccessGateway, AccessRoute, AccessDomain, InstanceHostname (9) |
| FluxVale.Pricing | yes | Size, TaxRate |
| FluxVale.Billing | yes (show_resources: Wallet, LedgerEntry) | Wallet, LedgerEntry in; Topup excluded |
| FluxVale.Feedback | yes | Post, Vote, Comment, Tag, PostTag (5) |
| FluxVale.Identity | no | — (excluded: User, Token, AuthCode, DeviceCode, PersonalAccessToken, UserEmail) |
| FluxVale.Accounts | no | — (excluded: Organization, Membership, MembershipInvite) |
| FluxVale.Api | no | — (excluded: AuditEvent, RequestWindow) |

Total in-registry: 23 resources across 6 domains (2+3+9+2+2+5).

Per-resource action surfaces (creates / updates / destroys, from the
transcript; registry intent curation derives from these):

- Ops FeatureFlag: create `:create`; update `:update`; destroy `:destroy`.
- Ops AccessRule: `:create` / `:update` / `:destroy`.
- Catalog Category, App, AppVersion: `:create` / `:update` / `:destroy`.
- Pricing Size, TaxRate: `:create` / `:update` / `:destroy`.
- Billing Wallet: create `:create`(system-only, hidden); updates
  `:set_carryover`, `:set_ladder_state` (system-only, hidden),
  `:set_waiver`; no destroy.
- Billing LedgerEntry: creates `:create` (system-only, hidden),
  `:grant_goodwill`; no updates; no destroys.
- Billing Topup: excluded from registry (gateway-driven rows).
- Infrastructure Cluster: `:create` / `:update` / `:destroy`.
- Infrastructure Instance: create `:create`; updates `:update_status,
  deploy, stop, start, sleep, touch, set_always_on, set_exposure,
  resize` (registry: workflow-labeled, visible where can? allows) and
  `perform_deploy, perform_reconcile, perform_settle, settle_anchors,
  perform_teardown, mark_deploy_error, mark_teardown_error`
  (machinery, excluded); destroy `:destroy`.
- Infrastructure InstanceAllocationSnapshot: create `:record`,
  update `:supersede` (system paths — read-only in registry, note set).
- Infrastructure BackupSetting: creates `:create`, `:save`; updates
  `:update`, `:save_settings`; destroy `:destroy`.
- Infrastructure BackupRun: create/update system-only (excluded);
  read-only in registry.
- Infrastructure AccessGateway: update `:update_credential, suspend,
  resume` (visible where can? allows); `update_state,
  set_api_token_ref, update_claims, perform_observe, perform_provision,
  perform_settle, perform_teardown, mark_provision_error,
  mark_teardown_error` (machinery, excluded); destroy
  `destroy_after_teardown` (system-only, excluded).
- Infrastructure AccessRoute: create/destroy system-only; read-only.
- Infrastructure AccessDomain: creates `:register` (visible),
  `mint_platform` (system, excluded); updates `:resume` (visible),
  `mark_verified, mark_failed, mark_needs_attention, mark_suspended`
  (observed state, excluded); destroy `:remove` (visible).
- Infrastructure InstanceHostname: create `:mint` (system, excluded);
  read-only.
- Feedback Post: `:create` / `:update`, `:set_status`, `:set_tags` /
  `:destroy` — all visible (paying gate passes admins).
- Feedback Vote: `:cast` / — / `:retract` (destroy action named
  retract; visible per gate).
- Feedback Comment: `:create` / — / `:destroy`.
- Feedback Tag: `:create` / `:update` / `:destroy`.
- Feedback PostTag: `:create` / — / `:destroy` (note points at
  Post `:set_tags` as the curated path).

Attribute type census over the 23 (renderer coverage map): UUIDv7
23/23 (pks), UUID (FKs, most), String, CiString, Integer, Decimal,
Boolean, Atom-with-one_of, custom enums (EntryReason, EntryType,
CustomerType, TopupStatus, InstanceStatus, InstanceExposure,
BackupRunKind, BackupRunStatus, AccessGatewayProvider,
AccessGatewayState, AccessDomainKind, AccessDomainState),
UtcDateTime/Usec, Map, custom composites (EnvVarSchema,
FirstRunContract). Pagination: every primary read is countable +
offset (max 250), verified in the transcript.

## Appendix B — policy probe evidence

`Ash.can?({resource, action}, actor)` runs (test DB, 2026-11-08):

```
FeatureFlag read:    admin=true  user=false
FeatureFlag create:  admin=true  user=false
FeatureFlag destroy: admin=true  user=false
Wallet read:         admin=true  user=true(maybe→true)   (member arm is filter-shaped)
Wallet create:       admin=false user=false   (system-only forbid)
Wallet set_waiver:   admin=true  user=false
LedgerEntry read:    admin=true  user=true(maybe→true)   (member arm is filter-shaped)
LedgerEntry create:  admin=false user=false   (system-only forbid)
LedgerEntry grant_goodwill: admin=true user=false
Instance read:       admin=true(maybe→true) user=true(maybe→true)   (filter-shaped; see D2)
Cluster read:        admin=true  user=false   (blanket admin arm, no filter)
Feedback Post read:  admin=true  user=true    (public read, always())
Feedback Post set_status: admin=true user=false
```

The Instance line is the D2 evidence: `relates_to_actor_via` is a
filter check; without an admin arm the READ silently scopes to the
actor's own orgs (an operator sees an empty table where AshAdmin
showed rows). Wallet/LedgerEntry reads carry explicit platform-admin
arms today (the #140/#571 pattern slice 5 generalizes).
