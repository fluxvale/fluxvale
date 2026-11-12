# ADR-0052: In-place instance env updates — the merge verb and the one Secret seam

**Status**: Accepted (owner go Nov 12, 2026, #731 — the plan is
[plans/731-terraform-integrations.md](../plans/731-terraform-integrations.md))
**Date**: 2026-11-12

**Context**: an instance's env vars are fixed at create. The API
accepts them only on `POST /instances`, the row then owns them, and
a change today means destroy-and-recreate — which is data loss for a
stateful app and the exact thing a second integration triggers. The
SSO retrofit (#597 S5) proved the narrow version of the missing
primitive: rewrite the `app-env` Secret, then roll the Deployment,
scoped to the recipe's keys. Terraform's `env_vars` inherits the
create-only limitation (`RequiresReplace`), so adding an integration
to a running app destroys it. The friends beta makes that a
second-deploy experience.

**Decision**:

1. **One merge verb.**
   `PATCH /api/v1/instances/:id/env`, `instances:write`, member-only,
   body `{set: {KEY: value}, remove: [KEY]}`. Input is write-only:
   the instance detail response never echoes env (the existing
   `hide_fields` posture). `set` and `remove` are explicit — no
   whole-map replace, no null-means-delete.
2. **The row is the truth; the Secret is a projection.** The public
   action writes the row's `env_vars` and the live `app-env` Secret in
   one transaction under the row's `FOR UPDATE` lock (the
   `AdoptCurrentRow` serialization stance). The row is what a
   subsequent deploy projects; the Secret is what running pods read.
   A failed Secret write rolls that row back (the Secret apply is
   atomic, so both stay old). The SSO legs commit their row first (the
   row is truth), then apply under the same lock: a failed apply leaves
   the recorded wiring with stale pods — the documented retry posture,
   never a half-rolled row. A patch touches only its own keys; an
   untouched live key that drifted from the row stays as the live
   Secret has it until the next deploy re-projects the row. The
   rolling restart is post-commit: a refused restart leaves the new
   row and Secret applied and the pods on the old env — visible and
   repaired by a redeploy; retrying the same patch is a no-op by
   design.
3. **Removal is explicit.** `remove` drops keys from the row and the
   Secret; a key absent from the ROW is not proof of absence from the
   live Secret (drift), so an explicit applied remove always reaches
   the Secret and may roll once. An empty string is a value, not a
   removal; `set`/`remove` overlap is refused. Removing a
   catalog-default key is allowed and persists: defaults are merged
   only at create (`DeriveFromAppVersion`), never re-applied on a
   redeploy. Values must be strings (the k8s Secret's contract); the
   create-time schema validation (`ValidateEnvVars`) runs on the
   merged map.
4. **Platform-composed keys: three categories, honest refusals.**
   Three sets are composed above the row, and a patch cannot own them:
   - **Deployer-composed** — the app version's `oidc_wiring` env names
     (when a wiring row exists), the instance's backing-service
     `url_env` keys, and the version's `instance_url_env`. A `set`
     refuses with the key names; a `remove` is skipped (no-op, logged)
     so a Terraform apply that stopped naming the key converges. OIDC
     recipe keys and `instance_url_env` match EXACT-case (a user's
     `root_url` is a distinct k8s key from the platform's `ROOT_URL`);
     backing-service `url_env` keys FOLD, mirroring the create path's
     conservative superset (`DeriveFromAppVersion.backing_conflicts/2`).
   - **First-run contract `env`** — FIXED. Both a `set` and a `remove`
     refuse with the key names: the contract lands at create and is
     never re-composed, so a removal would silently drop a guaranteed
     first-run value and accepting a set would be a lie.
   - **First-run contract `forbidden_env`** — NEVER SETTABLE. A `set`
     refuses; a `remove` is allowed cleanup (the platform never
     composes them).
   Contract matching is CASE-INSENSITIVE, mirroring the create path's
   fold (`DeriveFromAppVersion.contract_conflicts/2`); the deployer set
   is exact for OIDC/URL keys and folded for backing URLs.
   `host_allowlist_env` stays user-writable because the deployer
   appends the platform hostname to the user's value; the in-place path
   composes the same append for the live Secret only (one shared
   helper), never for the row — so the next deploy appends exactly
   once, and an unclaim does not leave a stale host in the row.
5. **Status rules.** `pending`/`error`/`lost`: row only (the next
   deploy ships it). `running`/`starting`: row + Secret + rolling
   restart. `stopped`/`sleeping`: row + Secret, no restart (pods are
   absent; the next start reads the updated Secret). `deploying`/
   `restoring`/`deleting`: refused — a deploy or restore owns the
   instance exclusively, and a delete has nothing to reach. The row
   lock is what makes "refuse" honest: the deploy holds it across its
   K8s applies.
6. **Audit content.** The PaperTrail version row records the action
   (`update_env`), the actor, the operation id, and `env_vars`
   redacted (ADR-0048); the write-only `set` argument is sensitive too,
   so the trail stores `REDACTED`, never a value. The `update`/`create`
   event for a system SSO merge (`merge_system_env`) is likewise
   sensitive — its `env` argument carries the OIDC client secret. The
   API boundary already writes its request row (`Api.AuditEvent`:
   method + path). One structured `:info` log line carries the instance
   id, actor id, and the added/changed/removed **key names** — plus
   `composed` when the allowlist append ran — never a value. That is
   the whole audit: no new table, no new resource, no migration. A test
   pins a sentinel value's absence from the response, the logs, and the
   version row.
7. **One Secret seam, generalized.** `ApplyPocketIdEnv` becomes
   `Operations.InstanceEnvSecret`: `upsert/5` (read-merge-write SSA;
   `expect_existing` refuses a lost Secret instead of creating a
   partial one), `restart/2` (annotation bump plus the app container's
   `envFrom` ensure, for the live statuses and the SSO legs; a
   stopped/sleeping first env instead uses the spec-only
   `ensure_env_from/2`, no rollout), and `apply_locked/4` (re-read the
   row `FOR UPDATE`, then upsert + restart; `expect_existing` comes
   from the caller's PRE-MERGE row) for the SSO operations. The public
   env action uses the same module with its own row transaction; no
   parallel K8s path exists. The SSO callers keep passing only their
   recipe keys — the ownership guard is the public action's, not the
   seam's. A deployed row that carries env but has no live `app-env`
   Secret is a 400 ("redeploy to repair"), never an empty-map merge
   that would boot the app without its other env. The same copy covers
   the public action's post-commit restart/ensure refusals: retrying
   the same patch is a no-op, so a redeploy repairs; the SSO legs
   always upsert + restart on retry, so their retry does converge.
8. **What a redeploy does.** It re-projects the row: in-place changes
   survive, removed keys stay removed, and the deployer's derived
   values (URL, backing URLs, SSO recipe keys) are composed above the
   row as before. A successful rollout after an in-place change is
   never reverted by the next deploy — the row carries it.
9. **Provider contract.** `fluxvale_instance.env_vars` updates in
   place: the provider diffs state vs plan into `set`/`remove`, sends
   one PATCH, and keeps the configured map in state (read never
   touches it). A null/omitted map clears the keys that resource
   previously managed. A platform-owned key the resource happens to
   still hold is skipped by the server (decision 4), so the apply
   converges instead of dead-ending. Import leaves `env_vars` null —
   the first apply that sets them sends a full `set`. `env_vars`
   stays sensitive; the state carries what the user configured.

**Rejected alternatives**:

- **Whole-map replace on update** — no removal semantics without
  nulls, and any read-modify-write by a client can lose a concurrent
  change. The merge verb is smaller and idempotent.
- **One PATCH per key** — N requests, N rollouts, and a partial
  multi-key change is unrepresentable.
- **A second K8s env path for the public API** — the SSO ops already
  encode the ordering lesson (Secret first, restart second, never the
  reverse); a parallel implementation would drift.
- **Row-only writes (defer to the next deploy)** — the caller asked
  for a running change; "it lands eventually" is the current bug in
  different clothes.
- **Secret-only writes (leave the row)** — the next redeploy would
  silently revert the change. The row must carry it.
- **A new env-audit table** — the version row, the request row, and
  the key-name log answer who/when/what without a schema change.

**Consequences**:

- `env_vars` becomes a live control surface; the instance page still
  does not edit it (UI out of scope), but the API, CLI, and Terraform
  can. No migration.
- The env write holds the row lock across a Secret apply — the same
  window the deploy already holds across its applies. A concurrent
  deploy, SSO write, or in-place patch serializes, never interleaves:
  the SSO legs take the same lock via `apply_locked/4`.
- A no-op patch is the empty final effect — `added`, `changed`,
  `removed`, and `composed` all empty AND no applied remove. It writes
  no Secret, rolls nothing, and does not resolve the cluster or
  read/repair the live Secret: row/Secret drift and a missing Secret
  surface on the next effective change (decision 7's 400) or on a
  redeploy.
- A restart or spec-ensure refusal is a 400 with the honest
  partial-state message ("the environment was saved, but ... — redeploy
  to repair"); readiness is not awaited (the SSO rotate's documented
  limit), and retrying the same public PATCH is a no-op by design.
- The provider's 0.3.0 changes a previously destructive diff into an
  in-place one; the compatibility note says so. Existing state needs
  no migration.
- `merge_pocket_id_env` is renamed `merge_system_env` — one system
  funnel for env merges, and the audit action name stops naming one
  integration.
