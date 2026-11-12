# ADR-0052: In-place instance env updates — the merge verb and the one Secret seam

**Status**: Proposed (awaiting owner go, #731 — the plan is
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
2. **The row is the truth; the Secret is a projection.** An env
   update writes the row's `env_vars` and the live `app-env` Secret
   in one transaction under the row's `FOR UPDATE` lock (the
   `AdoptCurrentRow` serialization stance). The row is what a
   subsequent deploy projects; the Secret is what running pods read.
   A failed Secret write rolls the row back (the Secret apply is
   atomic, so both stay old). A patch touches only its own keys; an
   untouched live key that drifted from the row stays as the live
   Secret has it until the next deploy re-projects the row. The
   rolling restart is post-commit: a refused restart leaves the new
   row and Secret applied and the pods on the old env — visible,
   retryable, and converged by the next retry or redeploy.
3. **Removal is explicit.** `remove` drops keys from the row and the
   Secret; a missing key is a no-op; an empty string is a value, not
   a removal; `set`/`remove` overlap is refused. Removing a
   catalog-default key is allowed and persists: defaults are merged
   only at create (`DeriveFromAppVersion`), never re-applied on a
   redeploy. Values must be strings (the k8s Secret's contract); the
   create-time schema validation (`ValidateEnvVars`) runs on the
   merged map.
4. **Platform-owned keys: sets refused, removes skipped.** The app
   version's `oidc_wiring` env names (when a wiring row exists), the
   instance's backing-service `url_env` keys, and the version's
   `instance_url_env` are composed by the deployer above user env. A
   patch that **sets** one is refused with the key names — the
   ADR-0045 D6 "reject loudly, never retcon" stance, applied at the
   live-write seam (the value would be silently overridden, so
   accepting it would be a lie). A patch that **removes** one is a
   no-op: the platform keeps its key, the skipped names are logged,
   and the request succeeds — a removal cannot win by design, and a
   refusal would dead-end a Terraform apply that no longer mentions the
   key. `host_allowlist_env` stays
   user-writable because the deployer appends the platform hostname to
   the user's value; the in-place path re-applies the same append (one
   shared helper), so a patch can never drop the platform's entry.
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
   redacted (ADR-0048). The API boundary already writes its request
   row (`Api.AuditEvent`: method + path). One structured `:info` log
   line carries the instance id, actor id, and the added/changed/
   removed **key names** — never a value. That is the whole audit:
   no new table, no new resource, no migration. A test pins a
   sentinel value's absence from the response, the logs, and the
   version row.
7. **One Secret seam, generalized.** `ApplyPocketIdEnv` becomes
   `Operations.InstanceEnvSecret`: `upsert/4` (read-merge-write SSA),
   `restart/2`, and `apply_to_running/4` (upsert + restart) for the
   SSO operations. The public env action uses the same module; no
   parallel K8s path exists. The SSO callers keep passing only their
   recipe keys — the ownership guard is the public action's, not the
   seam's.
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
  deploy or SSO write serializes, never interleaves.
- A restart refusal is a 400 with the honest partial-state message
  ("the environment was saved, but the rolling restart was refused —
  retry"); readiness is not awaited (the SSO rotate's documented
  limit).
- The provider's 0.3.0 changes a previously destructive diff into an
  in-place one; the compatibility note says so. Existing state needs
  no migration.
- `merge_pocket_id_env` is renamed `merge_system_env` — one system
  funnel for env merges, and the audit action name stops naming one
  integration.
