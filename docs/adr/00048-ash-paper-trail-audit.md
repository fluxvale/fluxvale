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

1. **One config posture, verbatim on every versioned resource.**

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
     belongs_to_actor :user, FluxVale.Identity.User,
       domain: FluxVale.Identity,
       on_delete: :nilify
   end
   ```

   `:uuid_v7` matches [ADR-0032](00032-uuid-v7-ids.md). `:changes_only`
   keeps rows compact and is atomic-trackable (`:full_diff` is not).
   Action name + inputs give the audit view the verb and arguments.
   `sensitive_attributes :redact` records THAT a sensitive attribute
   changed, never the value — the blanket posture, because sweep-set
   resources carry sensitive attrs (invite and PAT token hashes).
   `reference_source? false` + `create_version_on_destroy? true` is the
   audit-grade pair: no FK from version to source, so a destroy's
   evidence survives the record's own deletion (proven in A2-S1: the
   `:destroy` row outlives the flag). `operation_id` correlates the
   multi-record writes one action causes. `on_delete: :nilify` on the
   actor: a user deletion keeps the history and drops the pointer —
   the honest record, revisit when the data-deletion policy finalizes.
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
4. **Version reads ride the source's read policies**
   (`apply_can_read_policy? true`, D7): authorization-on-by-default
   holds on the version tables — admins read, members are Forbidden
   (proven on Ops). A2-S1 probe finding: versions of **destroyed**
   sources filter out for everyone under this mechanism (the
   `exists(version_source)` check cannot match a gone row). The A2-S4
   audit view reads destroy evidence system-side or adopts the plan's
   fallback (a mixin-injected admin-only version-read policy);
   decided when that slice builds the surface.
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
   the audit view's indexes (`version_source_id`, `user_id`) plus the
   actor label, referenced verbatim by every versioned resource's
   `mixin` option — the version-table posture cannot drift as the
   rollouts land.
7. **Surfacing**: a dedicated Audit console section (A2-S4) — version
   resources stay OUT of the generic resource console, excluded by
   name with reasons (the registry's per-resource exclusion seam,
   D9); the audit trail is a
   cross-resource view, not 29 raw tables. AshAdmin may render version
   resources on `/admin/ash` — accepted (trusted-superuser debug
   posture, [ADR-0027](00027-admin-surface-ashadmin.md) Am. 1).

## Notes from the A2-S1 probes (ash_paper_trail 0.8.1)

- `version_action_inputs` on atomic updates stores the input keys with
  nil values (upstream reads the non-atomic attributes map);
  `changes` carries the true values. Cosmetic for the audit view;
  revisit on a deliberate dep bump.
- Identical-value re-submissions write a version row (Ash's `changed?`
  means "the changeset carries changes", not "values differ"); an
  update that submits nothing writes none.
- The version tables' `uuidv7()` DB default never fires in practice —
  ids are Ash-generated per [ADR-0032](00032-uuid-v7-ids.md); the
  default is the generator's, left untouched so `ash.codegen --check`
  stays the drift gate.

## Rejected alternatives

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
  is the audit arc that closes that gap.
- [ADR-0032](00032-uuid-v7-ids.md): uuid_v7 version ids.
- [ADR-0013](00013-additive-migrations.md): the version tables are
  additive-only new tables; no source table changes.
- [ADR-0030](00030-ops-domain.md) / [ADR-0023](00023-day-one-gates.md):
  Ops hosts the proof slice (`FeatureFlag`, `AccessRule`).
- The resource console plan
  ([595](../plans/595-resource-console.md)): the registry parity test
  gained its per-resource exclusion seam here.
