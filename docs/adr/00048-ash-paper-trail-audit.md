# ADR-0048: Audit trail — AshPaperTrail over the business set, one config posture

**Status**: Accepted
**Date**: 2026-11-09

**Context**: The owner's Nov 9 doctrine (issue #644): an admin can do
anything in the admin surface, "that said, I think we should implement
AshPaperTrail so we have auditing capabilities" (#645). If every
mutation may be an admin action, every mutation must be attributable.
The implementation contract is the [plan](../plans/644-admin-authority-audit.md)
(Arc 2); slice A2-S1 proved the posture on Ops (`FeatureFlag`,
`AccessRule`), and the rollout slices extend it verbatim to the
29-resource business set (the plan's shared table — the same set Arc 1
widens authority over; the six machinery resources stay out: ephemeral
auth machinery, append-only telemetry, the machine-API audit and its
janitor bookkeeping, each named with its reason there).

## Decision

1. **One config posture, complete and verbatim on every versioned
   resource.**

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
     version_extensions authorizers: [Ash.Policy.Authorizer]

     belongs_to_actor :user, FluxVale.Identity.User,
       domain: FluxVale.Identity,
       on_delete: :nilify
   end
   ```

   The mixin line is **mandatory, not optional** — it carries the read
   policy (Decision 4), the audit view's indexes, and the actor-label
   tombstone; a resource omitting it ships policy-less version tables.
   The `version_extensions` line attaches the Policy authorizer that
   the mixin's policy rides on (probed: without `apply_can_read_policy?`
   the generated resource carries no authorizer, and the authorizer is
   what makes the mixin's policies section compile and enforce).

   `:uuid_v7` matches [ADR-0032](00032-uuid-v7-ids.md). `:changes_only`
   keeps rows compact and is atomic-trackable (`:full_diff` is not).
   Action name + inputs give the audit view the verb and arguments.
   `sensitive_attributes :redact`: 0.8.1 writes `REDACTED` for every
   sensitive attribute into every version's `changes`, changed or not,
   so the changes map can overstate what moved on sensitive-bearing
   rows — never the value, and that trade is accepted; whether a
   `changed?` guard is worth adding is deliberately deferred to the
   Identity/Accounts rollout (A2-S3), where the first sensitive-bearing
   resources version. `reference_source? false` +
   `create_version_on_destroy? true` is the audit-grade pair: no FK
   from version to source, so a destroy's evidence survives the
   record's own deletion, and the destroy row's own `changes` is empty
   (`:changes_only` has no deltas on destroy) — the final state
   reconstructs by replaying the record's version chain, and the
   destroy row itself answers who/what/when (pinned in the proof
   tests). `operation_id` correlates the multi-record writes one action
   causes. `on_delete: :nilify` on the actor: a user deletion keeps
   the history and drops the pointer — the honest record, revisit when
   the data-deletion policy finalizes.
2. **Attribution**: `belongs_to_actor :user` answers WHO for both actor
   kinds — a PAT's actor IS the User; system writes (Oban, webhooks,
   seeds) record nil, the honest system attribution. The web-vs-PAT
   channel is not a column in v1: every PAT call already writes a
   per-request `Api.AuditEvent` row and versions carry `operation_id`
   — correlation, not duplication. Revisit trigger: the owner wants
   the channel on the row — `paper_trail` `metadata` +
   `context.paper_trail_metadata` from the two boundary plugs is the
   mechanism.
3. **The actor-label tombstone (the plan's D6 probe — landed).** The
   shared version mixin adds an `actor_label` attribute and an
   on-create change (`FluxVale.PaperTrail.ActorLabel`) capturing the
   write-time `username`, so a deleted actor's versions still answer
   WHO after `on_delete: :nilify` drops the pointer. Cost: one
   attribute + one change inside the already-needed mixin, nothing
   per-resource — under the rider's "a line or two" bar, so it ships.
4. **Version reads: a DIRECT platform-admin-only policy on the mixin**
   (D7, revised on hostile-review evidence):
   `policy always() do authorize_if(FluxVale.Checks.ActorIsPlatformAdmin) end`.
   Members and anonymous callers are Forbidden for ALL version tables,
   regardless of the source's own read policies — source-policy replay
   (`apply_can_read_policy?`) was probed in A2-S1 and rejected: it
   makes version rows readable by whoever can read the source
   (including anonymous callers once public-read sources like Feedback
   or Catalog version), and its `exists(version_source)` check filters
   out destroyed-source rows for every actor, admins included. The
   direct policy fixes both: non-admins never read a trail row, and
   admins read orphaned destroy evidence through policies (asserted
   in the proof tests). The authorizer attaches via the posture's
   `version_extensions` line; `apply_can_read_policy?` is dropped.
   Members get no version reads in v1 — the audit view is
   admin-surface-only, and a member surface, if ever, is a deliberate
   future policy.
5. **Retention: forever — a deliberate judgment call under the owner's
   doctrine.** Relay record (PA rider): put to the owner with the plan,
   accepted 2026-11-09 — version rows are compact diffs, friends-beta
   volumes make time-boxing premature, and an audit trail with a
   janitor is only an audit trail back to the janitor's horizon. A
   future reader sees a decision, not an oversight. Revisit triggers:
   cost/scale pressure, the data-deletion policy finalizing. The
   existing janitor pattern (`prune_audit_events`,
   `prune_request_windows`) is the ready shape if a horizon is ever
   demanded.
6. **The shared version mixin** (`FluxVale.PaperTrail.VersionMixin`):
   the read policy, the audit view's indexes (`version_source_id`,
   `user_id`), plus the actor label, referenced verbatim by every
   versioned resource's `mixin` option — the version-table posture
   cannot drift as the rollouts land.
7. **Surfacing**: a dedicated Audit console section (A2-S4) — version
   resources stay OUT of the generic resource console, excluded by
   name with reasons (the registry's per-resource exclusion seam,
   D9); the audit trail is a cross-resource view, not 29 raw tables.

## Recorded truths (trust classes the doctrine accepts)

- **The `ash_paper_trail?` context bypass is caller-settable.** The
  extension's own version-create bypass rides a context key any caller
  could set — the same trust class as `authorize?: false`, guarded by
  the same discipline (internal call sites only, commented). The audit
  view must never forward request-derived context into version reads
  or writes.
- **AshAdmin can edit version rows directly.** The `/admin/ash` mount
  runs `authorize?: false` ([ADR-0027](00027-admin-surface-ashadmin.md)
  Am. 1), so an operator can mutate trail rows there. ACCEPTED: the
  doctrine attributes mutations, it does not tamper-proof against the
  operator's own debug mount — the same superuser trust class ADR-0027
  Am. 1 already records. Deliberately not excluded in this slice.
- **Topup buyer evidence is redacted-by-flag.** The buyer-evidence
  attributes (`buyer_email`, `buyer_name`, `billing_country`,
  `billing_state`, `customer_type`, `vat_number`, `ip_country`,
  `reverse_charge?`, `ip_matches_billing?`) carry `sensitive?(true)`,
  so the blanket `sensitive_attributes :redact` keeps their values out
  of the trail — version rows carry REDACTED markers, amounts and
  statuses stay plaintext. The erasure question stays OPEN: a deleted
  user's buyer evidence surviving as REDACTED markers (the marker
  proves a value existed, not what it was) is the data-deletion
  policy's call, not silently settled here.
- **Comment and Vote trails end at create.** Both resources' post FK
  cascades at the DB (`on_delete :delete` — the dependent-records
  posture), so a moderation delete of a Post takes its comments and
  votes without per-row destroy versions; the parent Post's destroy
  version row, with its actor, IS the audit record for the dependent
  rows' deletion. Deliberate: restructuring destroy flows to per-row
  trails would buy noise, not accountability.
- **Counter bumps never version the post.** The cached
  `vote_count`/`comment_count` are derivative data, recomputable from
  the Vote and Comment rows. In ash_paper_trail 0.8.1
  `ignore_attributes` filters the recorded DIFF but the write trigger
  is the changeset's own `changed?` flag — which the bumps' atomic
  updates set — so the bumps ride dedicated actions
  (`:bump_vote_count`, `:bump_comment_count`) silenced by name via
  `ignore_actions`. `updated_at` still moves on vote/comment activity
  (any update touches the timestamp), so the sitemap's re-crawl
  semantics are unchanged.
- **The redaction `changed?`-guard was evaluated and declined at
  A2-S3.** 0.8.1 lands every sensitive attribute as REDACTED in every
  version row's `changes` (and inputs) whether or not it moved. Kept:
  the marker is honest — it says the attribute exists and is
  protected, not that it changed — and a write-side guard would fork
  the dep's serialization. Pinned per sensitive-bearing resource in
  the proof tests (User, MembershipInvite, PersonalAccessToken).
- **Machine-cadence stamps ride the ignore lists.** The PAT auth
  path's `last_used_at` (per request), the Instance edge beacon's
  `:touch` bookmark and settle tick's metering cursors, and the
  gateway settle tick's `metering_since` (per 15-min tick) are
  machine cadence, not audit facts — the Post counters stance:
  `ignore_attributes` plus `ignore_actions` by name (0.8.1's write
  trigger is the changeset's `changed?` flag, so attribute-level
  ignoring alone cannot stop the row). State-machine fields and the
  wake clocks stay versioned. The audit surface for metering is the
  billing ledger (money movement) and the allocation snapshot
  history, not the anchor fields. Operator reachability of the
  silenced actions rides only the `/admin/ash` trusted-superuser
  mount ([ADR-0027](00027-admin-surface-ashadmin.md) Am. 1's accepted
  trust class, where every write is unversioned by construction).
- **Addresses in the trail are redacted markers.** The invitee
  address (MembershipInvite's `email`), the user_emails `address`,
  and the User signup/invite `email` arguments all carry
  `sensitive?`, so the trail holds REDACTED markers for every
  address-bearing write — the marker says an address existed and is
  protected, never what it was. The live address remains the row's
  own data: the redaction is a trail posture, not an erasure.


## Notes from the A2-S1 probes (ash_paper_trail 0.8.1)

- The authorizer probe: without `apply_can_read_policy?`, the
  generated version resource carries no Policy authorizer;
  `version_extensions authorizers: [Ash.Policy.Authorizer]` attaches
  it, and the mixin's direct policy enforces (admin reads pass
  including orphaned rows, member and anonymous reads are Forbidden).
- `version_action_inputs` on atomic updates stores the input keys with
  nil values (upstream reads the non-atomic attributes map);
  `changes` carries the true values. Cosmetic for the audit view;
  revisit on a deliberate dep bump.
- Identical-value re-submissions write a version row (Ash's `changed?`
  means "the changeset carries changes", not "values differ"); an
  empty update writes none. Both pinned in the proof tests as upstream
  semantics.
- The version tables' `uuidv7()` DB default never fires in practice —
  ids are Ash-generated per [ADR-0032](00032-uuid-v7-ids.md); the
  default is the generator's, left untouched so `ash.codegen --check`
  stays the drift gate.

## Rejected alternatives

- **Source-policy replay for version reads** (`apply_can_read_policy?`)
  — leaks reads to whoever can read the source (anonymous once public
  sources version) and filters orphaned destroy evidence for every
  actor; the hostile review of PR #651 proved both. Superseded by the
  mixin's direct admin-only policy.
- **`:snapshot` / `:full_diff` tracking** — row bloat, and `:full_diff`
  is documented non-atomic-trackable.
- **Per-resource config tuning** — one uniform block is the point;
  drift is the enemy of an audit posture.
- **`reference_source? true`** — a cascade-delete trail destroys its
  own evidence; theater, not audit.
- **A time-boxed janitor now** — premature at current volumes and
  weakens the premise (see Decision 5's triggers instead).
- **Policy-less version resources** — a hole in the repo's
  authorization-on-by-default discipline (D7).
- **Versions as generic-console registry resources** — the audit story
  is cross-resource; raw tables per resource say nothing (D9).
- **All 35 resources** — versioning ephemeral auth machinery is noise
  over secret-adjacent values; append-only tables are a trail of a
  trail (D5).

## Relationship to prior ADRs

- Extends [ADR-0027](00027-admin-surface-ashadmin.md) Am. 1's honesty:
  the `authorize?: false` admin surface was never audited; this ADR
  is the audit arc that closes that gap, and its recorded truths stay
  inside that amendment's superuser trust class.
- [ADR-0032](00032-uuid-v7-ids.md): uuid_v7 version ids.
- [ADR-0013](00013-additive-migrations.md): the version tables are
  additive-only new tables; no source table changes.
- [ADR-0030](00030-ops-domain.md) / [ADR-0023](00023-day-one-gates.md):
  Ops hosts the proof slice (`FeatureFlag`, `AccessRule`).
- The resource console plan
  ([595](../plans/595-resource-console.md)): the registry parity test
  gained its per-resource exclusion seam here.
