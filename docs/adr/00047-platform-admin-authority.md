# ADR-0047: Blanket platform-admin authority over the business set

**Status**: Accepted
**Date**: 2026-11-09

**Context**: The owner's Nov 9 doctrine (issue #644), verbatim:

> "There should not be a console admin. There are admins (for the
> FluxVale platform as a whole) and organization admins. admins should
> be able to have access to everything."

An admin dashboard that cannot see everything is pointless; the
per-resource admin arms accumulated so far (#140, #501, #577) widen one
policy at a time and drift the moment a new policy forgets its arm.
The implementation contract is the
[plan](../plans/644-admin-authority-audit.md) (Arc 1); slice A1-S1
lands the mechanism and the gate.

## Decision

1. **The blanket attaches to the EXISTING platform admin.** No new
   role, no new concept (owner correction, Nov 9): `platform_role ==
   :admin` on User, the account the admin already holds.
   `FluxVale.Checks.ActorIsPlatformAdmin` stays exactly what it is —
   the single answer to "is this actor a platform admin", shared with
   plug-land, byte-for-byte untouched.

2. **One condition-pair bypass, first in the policies block of every
   business-set resource:**

   ```elixir
   bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
     description("Platform admins see and do everything (#644)")
     authorize_if(always())
   end
   ```

   Ash's documented idiom for "an admin can do anything". When it
   passes, every other policy is skipped: platform-admin reads are
   cross-org by construction, not by per-resource arms. When its
   condition fails (non-admin, or a PAT-context call), an unsatisfied
   bypass simply falls through — every existing policy applies
   verbatim. It replaces User's and Cluster's former blanket admin
   policies (it subsumes them); all other existing arms stay exactly
   as they were, including FeatureFlag/AccessRule's and the
   catalog/pricing/feedback blankets. Interaction bypasses
   (AshAuthentication on User, AshOban on Instance/AccessGateway)
   remain ahead of it — bypass order carries no semantic weight.

3. **The blanket never rides a PAT.** The second condition,
   `FluxVale.Checks.CallOutsideMachineApi` (a call-property check —
   deliberately not actor-shaped: the same person is an admin actor on
   the console and a scoped credential at the machine API), answers
   "this call originates outside the machine API". Two rungs, and the
   refusal must survive NESTED action calls — a generic action's inner
   `get_by_id` re-reads with fresh options and drops the Ash request
   context, so both boundaries carry the process rung, which rides the
   request process and cannot be dropped (the review finding that
   proved it: an admin's token deleting a foreign instance through the
   inner-read fence):

   - `/api/v1`: the plug chain's existing PAT bridge
     (`FluxVale.Api.Scopes.pat_scopes_context_key/0`, written by
     `PutPatScopesInAshContext` for every PAT call) lands in the Ash
     request context; the check reads it through its subject. The same
     plug also marks the request process. The generic actions that
     nest reads (Instance `:delete`/`:run_backup`/`:restore_backup`,
     AccessDomain `:remove_via_api`, AccessGateway
     `:attach_instance`/`:detach_instance`) additionally PROPAGATE
     their `source_context` onto the nested calls — the context rung
     holds on its own for context-carrying callers, the process rung
     for everything else.
   - `/mcp`: phantom runs every tool handler in a worker process it
     spawns, so no request context carries the bridge's marker —
     `require_scope/2`, the first step of every handler in the MCP
     router, marks the process instead (the shared
     `mark_process!/0` helper is the one writer both boundaries call).

   Session callers and actorless system paths (Oban, webhooks, seeds)
   carry no marker: outside the machine API by definition. The
   surgical scoping: existing pure-actor arms (wallet/ledger reads,
   PAT read/create, `set_waiver`, `admin_lookup`, moderation) keep
   today's admin-PAT behavior byte-for-byte — an admin's token still
   passes exactly those arms and nothing more. The refusal lives on
   the bypass alone.

4. **Writes are admitted too — a deliberate judgment call (D4),
   flagged.** The bypass covers every action, including ones whose
   policies are `forbid_if(always())` system-only gates (Wallet
   `:create`, LedgerEntry `:create`, Topup create/update). The policy
   layer stops pretending an operator class cannot do what `/admin/ash`
   already lets them do `authorize?: false`
   ([ADR-0027](00027-admin-surface-ashadmin.md) Am. 1). What changes is
   reachability honesty, not reachability: the API route table has no
   routes for system-only actions, PAT actors never pass the bypass,
   and scope enforcement runs before policies anyway. The surfaces own
   what is OFFERED (the console registry's intent lists, the curated
   sections); the policies own what is PERMITTED. Relayed via the PA
   with the plan; a future reader sees a decision, not an oversight.
   The demotion window, stated plainly: reads are mount-resolved (the
   route pipeline plus the AdminGate socket re-check — a pre-existing
   posture this doctrine widens in scope, since a demoted admin's
   already-mounted live tab displays stale cross-org data until its
   next interaction or reconnect — on the generated tools, bounded
   to one cadence by ADR-0027 Am. 6's periodic redirect), while
   writes re-resolve the actor per event (#571/#617) — today
   satisfied by the WalletDetail surface and the console engine's
   write path, and the AdminChrome `handle_event` attach_hook
   (A1-S2; extracted into `FluxValeWeb.AdminDemotionGate` by #671,
   which also mounted it on the generated tools' sessions —
   view-level events only there; the component-targeted residue
   those sessions kept is bounded to one cadence by ADR-0027 Am.
   6's periodic re-resolve + redirect, not gated per-event) closes
   the interactive part for every admin LiveView.

5. **The two-tier role model — both tiers already in the schema.**
   Platform admin (`PlatformRole :admin`, FluxVale as a whole,
   everything — this doctrine) and organization admin (the org-scoped
   `MembershipRole` axis; today that tier is `:owner`, with `:member`
   as the expansion point and a dedicated `:admin` membership value
   the natural future slot). The axes are never conflated (both type
   moduledocs say so). Future scoped roles — if ever needed — are the
   ORG tier growing console-shaped powers through an org-admin grant
   resolver on the same policies; the platform bypass is untouched.
   What is rejected: a third platform tier or any "console admin"
   concept — killed by the owner Nov 9, before it ever shipped.

6. **The set: the plan's shared business-set table (31 resources).**
   Both arcs act on that one list; the machinery side is 9 — 7 named
   rows plus the 2 generated version resources' exemption — each with
   its reason there (the gate walks 40 configured resources: 38
   authored plus the 2 generated versions). The doctrine gate
   (`test/flux_vale/admin_authority_test.exs`) walks every resource of
   every configured domain and demands one of exactly three states:
   full (bypass AND paper trail), machinery exemption (by name, with
   reason), or trail-pending (the bypass live, the trail arriving with
   the named A2 rollout slice). A new resource fails CI until it joins
   a set deliberately — the doctrine survives resource growth. Three
   resources the plan's original census missed (the #597/#250 era:
   PocketIdCustody, PocketIdCustodyEvent, StorageRequest) were settled
   by the architect's Nov 9 amendment to the plan table, made on this
   PR: StorageRequest (the operator queue's business row) and
   PocketIdCustody (mutable operator-custody state, carrying
   `api_key_secret_ref` — a Secret NAME, never the value,
   `AccessGateway.credential_secret_ref`'s posture) joined the
   business set; PocketIdCustodyEvent stayed out as the seventh
   machinery row (append-only custody history — its own table IS its
   trail). Joining a set is a plan-table decision, enforced by the
   gate — never a silent gate edit.

## Rejected alternatives

- **Per-policy admin arms** (the #577/#613 pattern generalized) —
  ceremony ×100+, drifts silently when a new policy forgets the arm,
  and an arm inside one policy cannot rescue a `forbid_unless` gate in
  it.
- **God-mode PATs** (no refusal) — a silent contract change turning
  every admin token into everything-token.
- **Baking the refusal INTO `ActorIsPlatformAdmin`** — narrows today's
  reachable admin-PAT behavior on armed resources (wallet reads); a
  contract change nobody asked for.
- **An API admin scope** — same god-mode token, one indirection
  deeper.
- **Boundary-side restrictions at the plugs** — would change today's
  member-level admin-PAT behavior, exactly what D2 forbids.
- **A macro injecting the bypass** — hides the doctrine from grep.
- **Ash domain-level policies** — no such layer in Ash 3.37.
- **A "console admin" check/module** — forks the platform-admin notion
  against the one-module-one-question rule, and the concept is
  owner-dead.

## Relationship to prior ADRs

- [ADR-0027](00027-admin-surface-ashadmin.md) Am. 1: the `authorize?:
  false` superuser surface was the starting honesty; this ADR is the
  policy layer catching up (Decision 4).
- [ADR-0048](00048-ash-paper-trail-audit.md): the other half of the
  doctrine — widened authority meets attributable mutations. Neither
  arc ships alone.
- The resource console plan
  ([595](../plans/595-resource-console.md)): the registry's intent
  lists keep deciding what renders; this ADR's policies decide what
  passes.
