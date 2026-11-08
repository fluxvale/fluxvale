# Plan: storage beyond the self-service threshold — request → operator approval (#250)

Status: **APPROVED — PA, 2026-11-09** (overnight variant; Terence's standing grant
substitutes for the plan gate). All decisions D1–D8 settled as recommended. Three PA
riders recorded: (1) the runbook names the **prod** StorageClass
`allowVolumeExpansion` prerequisite explicitly — the k3d patch is a local-dev enabler
only, and a prod class change is a launch-checklist adjacency, never a worker
improvisation; (2) the 3¢/GB rate ships marked **PROVISIONAL** in config/seed, S6
(Terence's one-line ratification) stays #250's closer, and member-facing copy stays
rate-agnostic; (3) the 100 GB boundary finding is stated as an assumption below so the
morning reader sees the issue's original 400 GB number was wrong, not the implementation.
The pricing **number** is a morning ratification item — the mechanism ships tonight with
a provisional rate in configuration, never a business number in code.
Evidence base: issue #250 + its Oct 24 product decision, issue #243, [ADR-0043](../adr/00043-instance-resize.md)
(resize), [ADR-0028](../adr/00028-flat-rate-pricing.md) (pricing), [ADR-0027](../adr/00027-admin-surface-ashadmin.md)
Am. 4 (console sections), [ADR-0030](../adr/00030-ops-domain.md) (Ops domain), the code at
HEAD `7ff99edc`, and the live local k3d cluster probed on 2026-11-09.
This doc is the implementation contract for every slice; a worker implementing a slice
reads THIS FILE IN FULL before starting.

## 0. What the issue asks, and what shipped since it was written

**Assumption (corrects the issue).** The issue's Oct 24 note says "the ladder's top
storage rung — 400 GB once the pending ladder PR lands". That is wrong: the 400 GB `max`
shape was **rejected on #399** ([pricing-calibration](../pricing-calibration.md) keeps it
only as the rejection record), no pending ladder PR exists in the open set, and the
shipped storage ladder is `0, 5, 10, 20, 50, 100` GB
(`AllocationSliders.resource_dimensions/0`). This plan implements the shipped **100 GB**
boundary; the issue's 400 GB number is superseded, not a target. The threshold is
configuration (D1), parity-pinned to the ladder's top rung, so a future ladder move is a
one-line change plus the ladder edit — never a silent fork.

The Oct 24 decision: storage requests are not capped by the ladder, but storage the box
does not already hold needs procurement, so it flows through an operator approval queue:
request from the instance surface → queue + notification → operator orders capacity →
approve → the volume grows (PVC expansion, never shrink). Ordering stays manual in v1.

## 1. The design in one paragraph

A member opens a **storage request** on an instance's page: a target total GB (above the
100 GB self-service boundary), the current allocation as context, a short reason, and the
projected new monthly rate. The request lands as `requested` in an **operator queue** at
`/admin/storage-requests`; the console's sidebar badge and the queue itself update live
over PubSub (no polling, no email dependency). The operator orders and attaches capacity
per the internal fleet runbook, then **approves** in the queue. Approval is a durable
decision, immediately followed by a retryable **apply**: the platform settles the open
usage interval at the old rate, re-prices the new allocation through the create-equivalent
snapshot (now with a configurable marginal rate above the threshold), appends the
allocation era, patches the `app-data` PVC and the storage quota, and marks the request
`applied`. `rejected` requires feedback, which the member sees on the instance page.
Storage still only grows. The storage arm of #243 is thereby done: #243 narrows to
CPU/RAM when this lands.

## 2. Ground truth this builds on (verified, not assumed)

- **The ladder's top storage rung is 100 GB** on `main` (`allocation_sliders.ex`); the
  400 GB claim in the issue never landed (rejected on #399). The issue's "pending ladder
  PR" does not exist in the open PR set.
- **Resize already owns the storage mechanics**: `Instance :resize` is stopped-first,
  settles the open interval before the flip, re-prices through
  `Instance.PricingSnapshot.snapshot/3` (create-equivalent, fresh 1-year clock), appends
  the allocation era, and applies the PVC (`max(row, live)` — never shrinks) + quota via
  `ResizeInstance`. The storage capability is a live probe of the default StorageClass's
  `allowVolumeExpansion`, cached 5 minutes (`StorageExpansion`).
- **The local stack cannot expand today.** `kubectl get storageclass local-path` on the
  2026-11-09 cluster shows no `allowVolumeExpansion` (false); a probe PVC on a throwaway
  class with the flag set to `true` accepted a 1 Gi → 2 Gi spec patch, but the PV's
  capacity stayed 1 Gi (local-path is a directory on the host; the host disk is the real
  bound). So local acceptance is **spec-level growth** and needs a one-line local
  StorageClass enabler (D8); prod uses an expandable class (TopoLVM named in #493) and
  the probe self-unlocks.
- **The operator surfaces are the custom admin console** (`/admin`, `:admin` live_session,
  `AdminShell` sidebar, [ADR-0027](../adr/00027-admin-surface-ashadmin.md) Am. 4). The
  console is splitting into **purpose-built Sections** (People, Catalog, Wallets,
  Feedback, Orgs, Gateways) and the **domain-grouped Resources** console (#595). The
  queue is a workflow, so it belongs in Sections (D5), not as a generic resource leaf.
- **Notification is PubSub, not email.** The app's existing live-update mechanism is
  `Ash.Notifier.PubSub` (`instances:<id>`, #74). Prod cannot deliver mail yet
  (`Swoosh.Adapters.Local`, `docs/deployment.md`), so an operator email would die in the
  pod. The in-app badge + live queue is the only honest "sees it without polling" path
  today (D6).
- **The machine API has no admin scope** (`FluxVale.Api.Scopes`: "There is no admin
  scope"). Member verbs can ride `instances:read/write`; operator approval stays web-only
  in v1 (D8's API note).
- **Pricing is one function**: `Pricing.price_allocation/1` → `PriceAllocation` (curve v5,
  storage term `0.06 · gb^0.75 × 1.2`, rounded half-up), shared by the wizard estimate,
  the ledger charge, and `PricingSnapshot` (create and resize). One change here prices
  every surface; no second copy of a number.

## 3. The state machine

```
                 approve (operator)                 apply ok
  requested ───────────────────────► approved ───────────────────► applied
      │                                  │
      │ reject (operator, feedback       │ apply fails
      │ required)                        └──► approved + apply_error
      ▼                                       (retryable; decision already durable)
  rejected  (terminal) ◄── reject from approved when it can never apply
```

- **Four states, exactly the issue's machine**: `:requested`, `:approved`, `:rejected`,
  `:applied`.
- **Approve is a decision; apply is mechanics.** The approve action commits `approved`
  with `decided_at` / `decided_by_user_id`; the same operator click then runs the apply.
  If the PVC patch fails (transient API error), the row stays `approved` with an
  `apply_error` and a **Retry apply** button — the operator does not re-decide. If the
  process dies between the two writes, the queue shows an approved request waiting to
  apply. This is the honest split: a durable decision, a retryable mechanical step.
- **Reject is terminal** and requires `rejection_reason` (the user-visible feedback). The
  member's instance page shows it verbatim; no email is sent (prod mail is local).
- **Reject is also the escape hatch for an unappliable approval.** If an `approved`
  request can never apply (capacity cannot be attached, the instance is gone), the
  operator rejects it from `approved` with the same feedback contract — the four states
  are unchanged, and the one-open-request index releases. Never leave a customer waiting
  on an approval the infrastructure cannot honor.
- **One open request per instance**: a partial unique index on `instance_id` where
  `status IN ('requested', 'approved')` is the invariant's teeth (the `backup_runs`
  one-active-run precedent). A second submit is refused with copy, not a duplicate queue
  row.
- **Stale approvals refuse honestly**: if the instance was resized to or above the
  requested total between request and approve, the approve action says so; the operator
  rejects instead. Never a silent no-op.
- **No user cancel in v1**: the four-state machine is the promise. A member who needs a
  different amount asks the operator to reject (feedback) and re-requests. Recorded as an
  open question; a `cancelled` state or a withdraw action is a later one-line addition.

## 4. The resource

`FluxVale.Infrastructure.StorageRequest` (table `storage_requests`, UUIDv7 PK, timestamps,
`Ash.Policy.Authorizer`, `Ash.Notifier.PubSub`).

| field | type | notes |
|---|---|---|
| `instance_id` | uuid FK, cascade on delete | teardown takes the request along (BackupRun's posture) |
| `organization_id` | uuid | denormalized from the instance for the queue and policy; never accepted from input |
| `requested_gb` | integer | **target total**, not a delta (D1); min 1, max = policy `max_gb` |
| `current_storage_gb` | integer | snapshot at request, for the queue and audit |
| `reason` | string | required, ≤ 280 chars, trimmed |
| `status` | `Types.StorageRequestStatus` | `:requested` default; text-stored enum (the InstanceStatus stance) |
| `quoted_monthly_cents` | integer | the target rate shown at request (advisory; approval re-prices, D7) |
| `quoted_current_cents` | integer | the design-time "from" figure |
| `requested_by_user_id` | uuid | plain id, no FK (the request outlives a deleted user) |
| `decided_by_user_id` | uuid | operator id, plain |
| `decided_at` | utc_datetime_usec | |
| `rejection_reason` | string | required on reject, ≤ 500 chars |
| `apply_error` | string | admin-only (`public? false`); nil = clean |
| `applied_at` | utc_datetime_usec | |

Policies:
- **Member** create/read on an instance in their org (`relates_to_actor_via([:instance, :organization, :members])`).
- **Member** reads their org's requests only.
- **Platform admin** reads all, and runs `approve` / `reject` / `retry_apply` (the
  `ActorIsPlatformAdmin` arm).
- **System** `mark_applied` / `mark_apply_failed` run `authorize?: false` from the apply
  operation, with a comment (the trail/seed system-write posture); the operator gate is
  the request's own approve policy.
- **Creating a request is free**; the funded-wallet gate (the resize's #124 gate) bites at
  approval, where the queue shows the wallet state and an unfunded org is rejected with
  feedback instead of ordering capacity for it.

Actions:
- `create :request` — argument `:instance_id` (public, path-fed like
  `BackupSetting :save`), accept `[:requested_gb, :reason]`; a change loads the instance
  authorized, sets `organization_id` / `current_storage_gb`, quotes through
  `ResizePreview` (the same snapshot choice), and validates:
  target > current; target > `threshold_gb`; target ≤ `max_gb`; no open request; instance
  not `:deleting` / `:lost`.
- `read :for_instance` — argument `:instance_id`, newest first, capped (the member list
  and the API route).
- `read :get_by_id` — the single-request read behind `GET /storage-requests/:id`.
- `read :queue` — admin, filters status + search, newest first, capped at 100 (the
  moderation/people list ruling), `countable` for the badge. A plain `index([:status])`
  serves the count and the status filter.
- `update :approve` — requested → approved; `optimistic_lock(:version)`; requires the
  instance live, the target still > current, and the cluster capability
  `{:ok, true}` (runbook: attach, then approve); records the decision. No cluster I/O.
- `update :reject` — requested (or approved when the apply can never succeed) → rejected;
  requires `rejection_reason`.
- `update :retry_apply` — admin; approved with `apply_error` → re-runs the apply (no
  decision write).
- `update :mark_applied` / `:mark_apply_failed` — system; approved → applied / approved
  with error.

## 5. API verbs (member; operator stays web-only)

The machine API mirrors what a CLI/MCP caller can do without an operator identity:

- `POST /api/v1/instances/:id/storage-requests` — create (`instances:write`).
- `GET /api/v1/instances/:id/storage-requests` — list the instance's requests
  (`instances:read`).
- `GET /api/v1/storage-requests/:id` — one request (`instances:read`).

Implemented as `json_api` routes on the resource (the `BackupRun`/`BackupSetting` route
shape: a path-fed `:instance_id` argument). `FluxVale.Api.Scopes` gains the three route
patterns; the coverage test holds both directions. No admin scope exists, so approve/
reject/retry have **no** `/api/v1` route in v1 — the operator queue is the surface.

This slice regenerates the public schema: `mix flux_vale.open_api` and
`cargo xtask openapi` (from `apps/platform/priv/open_api.json`), committing
`apps/platform/priv/open_api.json` and `crates/fluxvale-api/src/types.rs`.

## 6. The member request UI (instance page)

Extends `InstanceLive.Show` beside the resize panel; no new route.

- A **Storage** card/row states the current allocation and the boundary:
  "50 GB · self-service up to 100 GB". The existing resize panel already knows the
  "above the top rung" case (`storage_fixed_line(:above_top, …)`); this card is its
  neighbour, not a replacement.
- **Request more** (available while running/stopped/sleeping; hidden for deleting/lost)
  opens an inline form:
  - target total GB (integer; min = `max(current + 1, threshold + 1)`, max = policy
    `max_gb` — 7,600 GB, the attachable ceiling; the row's hard attribute max is
    10,240, but the queue never accepts a promise the box cannot attach, step 1);
  - current context: "Currently 50 GB · self-service up to 100 GB";
  - a required short reason (≤ 280);
  - a live projected rate from `ResizePreview.call(instance, allocation_with_target)` —
    the same choice the apply charges, so the shown figure is the charged figure
    (unpriced → "Price confirmed at approval", never a guess);
  - copy: "We order capacity for this. You'll see the decision here; the rate is
    confirmed when it's approved." **Rate-agnostic**: the copy never names the mechanism,
    the per-GB rate, the COGS, or any internal number — it shows only the computed
    monthly figure for this request.
- **Open request state**: when a `requested`/`approved` request exists, the form is
  replaced by a status card — target, quote, submitted date, status; `rejected` shows
  the feedback verbatim and offers a new request; `applied` shows the applied date and
  the new rate.
- **Live updates**: the page subscribes to `["instances", instance_id, "storage-requests"]`
  and re-reads the request list on each notification (the DB is the ordering that cannot
  lie; never trust `notification.data`). The instance row's `:grow_storage` broadcast on
  `instances:<id>` re-reads the allocation as today.
- **Invalid target**: server validation is the authority; the form's note routes a
  within-boundary target to the resize panel ("That's within self-service — use Resize"),
  not a silent failure.

## 7. The operator queue surface

`/admin/storage-requests` — a **purpose-built Section** in `AdminShell` (D5), same
console chrome (`wide` + `appgram console`, the #593/#596 lane), not a generic resource
leaf.

- **Sidebar**: a new Sections entry "Storage requests" (live, not Coming), with a
  pending-count badge. The badge rides every admin page: `AdminChrome.on_mount`
  subscribes to the global queue topic and an attached `:handle_info` hook keeps the
  count assign fresh; `AdminShell.sidebar` takes the count and renders it. No polling.
- **List**: status chips (Requested default with count, Approved, Applied, Rejected,
  All), search over the request's own fields (reason, ids) and the org name where the
  admin lookup admits (id fallback), newest first, capped at 100 with overflow
  copy. Each row: instance + org, current → requested GB, delta, reason, requester, age,
  quoted rate, status badge, and the apply error when present.
- **Detail/expanded row**: the instance's live status and allocation, the org wallet
  state (funded / negative), the capability probe result, the approve confirm (current →
  requested, the charged rate from `ResizePreview`, "the instance keeps running; a
  restart may be needed to see the new space"), and the reject form (required feedback,
  "This goes to the customer verbatim"). Approve is disabled with the reason when the
  wallet is unfunded, the capability is false/error, the request is stale, or the
  instance is gone — the runbook's "order and attach first" made visible.
- **Approve one click**: approve + apply; success flashes "Applied — 200 GB on
  <instance>"; failure leaves the row Approved with the error and a Retry apply button.
- **Reads and writes** ride the Infrastructure/StorageRequest policies with the operator
  as actor, `authorize?: true`; every write re-resolves the actor from the session (the
  #571 demotion window, the console's contract).
- **Instance context is a scoped system read, not a widened member policy.** The instance
  read policy has no platform-admin arm today (the #603 finding), and this lane does not
  add one: the queue loads only the decision fields (status, storage, cluster/name) for
  the request's instance through a dedicated operator-context read after the admin gate,
  `authorize?: false` with a comment, never env/namespace/technical detail. The #595 D2
  read-arm decision remains its own lane. The wallet read rides its shipped
  platform-admin arm.
- **The raw table stays out of the generic resource console in v1.** A generic status
  edit would bypass the apply; when Infrastructure flips live in #595's registry, the
  intake decision is: `StorageRequest` joins as a read-only note (or a documented
  exclusion), never generic CRUD. The registry parity test forces the decision.

## 8. The notification path

- **On create**: `StorageRequest` publishes `:create` to the static topic
  `"storage_requests:queue"` and to `["instances", :instance_id, "storage-requests"]`.
- **On decision/apply**: `:approve` / `:reject` / `:mark_applied` publish the same two
  topics (updates ride the instance topic).
- **Operator**: the admin session subscribes to the queue topic; the sidebar badge
  increments and the mounted queue re-reads/re-streams. The operator sees a new request
  on any admin page without polling. No email in v1: prod cannot deliver it
  (`Swoosh.Adapters.Local`); revisit when the prod mailer lands (the recorded trigger).
- **Member**: the instance page subscribes to its request topic; the status card and the
  rejection feedback move live.
- Tests: PubSub tests pin both topics for create/approve/reject/apply (the
  `instance_pub_sub_test` shape); a LiveView test asserts a broadcast inserts a row and
  bumps the badge.

## 9. Approval → PVC expansion path

The apply is **storage-only and online** (D3), not the stopped-first resize:

1. **Re-read and guard** the request + instance (authorized for the decision; system for
   the apply): status approved; target > current; instance live; capability
   `{:ok, true}`; wallet funded (the resize's #124 gate; the queue shows the state).
2. **Settle before the flip**: settle the open usage interval at the old rate
   (`SettleUsage.settle_now/1`), so no hour straddles two prices (ADR-0043's ruling).
3. **Re-price** through `Instance.PricingSnapshot.snapshot/3` at the effective allocation
   (row CPU/RAM, new storage) — create-equivalent, fresh 1-year clock, and the storage
   term now carries the marginal overage rate above the threshold (D4).
4. **Append the era** (`AppendAllocationSnapshot`): close the open row, append the new
   allocation + cents + `effective_from`. Row and trail commit together.
5. **Apply the volume** (`GrowStorageVolume`, a new operation reusing the resize's storage
   arms): ResourceQuota (storage component) + PVC `max(row, live)` + the 0→N file-access
   world. On the **0→N file-access crossing** the Deployment is re-applied so the WebDAV
   sidecar exists (the resize's `maybe_mint_file_access_world` + deployment arm); on a
   normal N→M grow the Deployment is **not** touched — the pod does not roll, and the
   filesystem may need a restart to see the new size (stated in the approve copy).
6. **Update the instance row** (storage, pricing triple, clock) inside the action's
   transaction; the K8s apply rides `after_action` (the `set_exposure`/resize contract:
   the row never claims an allocation the cluster hasn't reached) — a failed apply rolls
   the row back and leaves the request `approved` + `apply_error`.
7. **Mark applied** and broadcast.

New `Instance :grow_storage` action: accepts `[:storage_gb]`, `require_atomic?(false)`,
`optimistic_lock(:version)`, a `StorageGrowthGuard` (up-only, no stopped-first,
capability-gated, settle-before-flip, normalize the effective allocation), then
`ResizePricing` + `AppendAllocationSnapshot` + the `GrowStorageVolume` after-action. It is
**system-only** (no policy arm, no JSON:API route); the approval operation calls it with
`authorize?: false` after the request's own approve policy passed. It publishes
`:grow_storage` on `instances:<id>`.

Reuse, don't fork: `ResizePricing`, `AppendAllocationSnapshot`, `StorageExpansion`,
`SettleUsage`, `PricingSnapshot`, `InstanceK8s.quota_spec`, and the `ResizeInstance` PVC /
0→N arms. The only new behaviour is "growth without the stopped-first fence". #243 later
narrows `:resize` to CPU/RAM and routes self-service storage through `:grow_storage`
(a stopped-first self-service storage decision for that lane, not this one).

## 10. Pricing (D4): the rule and the mechanism

**The COGS anchor:** block storage is €13/TB/month (≈ $14.04 at €1 ≈ $1.08), attachable
up to 7.6 TB. The block is a **shared pool** on the box (TopoLVM/local carves instance
PVCs from it), not a dedicated block per request — so per-GB pass-through is economically
sound; the runbook's order trigger is pool headroom, not each request.

**Option A — pass-through + margin (recommended).** Above the threshold, price each GB at
a configured marginal rate: COGS floor ≈ 1.4¢/GB/month (€13/TB ≈ $14.04 at the assumed
FX), plus a margin. The provisional default is **3¢/GB/month** (≈ $30/TB, ~53% gross over
the €13 COGS at the assumed FX) — deliberately above the floor, easy to lower in one line.
A 200 GB instance's storage rate = the existing curve at 100 GB (228¢) + 100 × 3¢ =
**$5.28/mo** (COGS ≈ $2.81, healthy margin); at 1 TB it is $29.28/mo vs €13 COGS; at
7.6 TB $227.28/mo vs €98.80 COGS.

**Option B — extend the per-GB curve.** The v5 curve at 1 TB is **$12.80/mo** against
€13 ≈ **$14.04 COGS** — underwater — and the gap widens: 2 TB $21.53 vs $28.08; 7.6 TB
$58.61 vs $106.70. Rejected as a rule; it cannot cover the procurement it triggers.

**Mechanism (same for either rule): configuration, not code.** One block:

```elixir
config :flux_vale, :storage_beyond_threshold, %{
  threshold_gb: 100,
  # PROVISIONAL — S6 (Terence's one-line ratification) sets the final rate.
  cents_per_gb: 3,
  max_gb: 7_600
}
```

`PriceAllocation.storage_usd_cents/2` prices the first `threshold_gb` on the existing
curve and the remainder at `cents_per_gb`. The marginal rate is the configured **effective
rate for the seeded region** — it is a COGS anchor, not a market-curve term, so the v5
surcharge does not multiply it (a second region gets its own configured rate when it
exists, a one-line map addition). `Pricing.storage_monthly_cents/1` — the one storage
seam used by `PricingSnapshot` (create, resize, approval), the stopped fee, the wizard,
and the calculators — carries it with zero call-site changes. A calibration test pins:
below/at the threshold unchanged (the whole existing table); above it the marginal
formula; the threshold equals the top storage rung (the parity gate against
`AllocationSliders`). The owner's morning ratification is a **one-line** config/seed
change plus a pricing-calibration doc row. No business number is hardcoded in code.

The request quote and the approval charge both go through `ResizePreview` /
`PricingSnapshot`, so the shown figure is the charged figure by construction. The quote
is **advisory** (D7): the apply snapshots the rates in force at approval; the copy says
"the rate is confirmed when it's approved". Before the morning ratification the
provisional rate is clearly a placeholder; no real customer exists pre-launch.

## 11. The runbook (internal)

New `docs/runbooks/block-storage.md`, linked from the docs map, deliberately **not** in
`docs/public` (ADR-0044's boundary: only `docs/public` + `docs/blog` are served). It
carries what the member copy must never: the vendor, the €13/TB cost, the fleet ledger
math, and the attach steps. Contents:

- the boundary and its config (`threshold_gb`), and the parity rule;
- the pool ledger: local usable capacity + attached blocks (N × 1 TB), allocated + reserved
  GB, the order trigger (order when approved-but-unattached + headroom crosses a block);
- the order steps (1 TB block), attach steps (attach to the box, extend the LVM volume
  group backing the expandable StorageClass, verify `allowVolumeExpansion`, canary-grow a
  PVC), and the local-stack note (local-path is spec-level only; the host disk is the
  bound);
- the approve-after-attach rule and the failure/retry path;
- pricing: the COGS anchor, the margin config's one-line home, and the "never in
  user-facing copy" rule;
- the 7.6 TB attachable ceiling: beyond it is a second box/migration, out of v1 — reject
  with feedback or escalate.

## 12. Decisions

### D1 — Threshold source and request amount semantics

- **Options**: (a) hardcode 100 in the request validator; (b) config
  `threshold_gb: 100`, parity-pinned to the ladder's top rung; (c) derive from the UI
  ladder at runtime.
- **Recommend (b)**, with the request amount as a **target total** (`requested_gb`), not
  a delta.
- **Why**: the validator needs a server truth; the ladder is UI business data; the parity
  test makes a future ladder move a two-line reviewed change, never a silent fork. A
  target total matches the instance row, the PVC, the price, and the queue; a delta needs
  a second piece of arithmetic everywhere. The stale 400 GB claim is corrected here (the
  shipped boundary is 100).

### D2 — Approval atomicity and the retry path

- **Options**: (a) approve = decision + synchronous apply in one transaction, rollback on
  failure; (b) approve is durable, the apply is a retryable second step (approved +
  `apply_error`); (c) fully async Oban apply.
- **Recommend (b)**, one click: the approve action commits the decision, the operation
  immediately applies; a failed apply leaves `approved` + an error and a Retry button.
- **Why**: the operator's decision should not be lost to a transient API error, and
  re-deciding after a retry is friction. A rolled-back approval (a) hides that the
  decision was made; an Oban queue (c) adds a worker and a hidden state for a synchronous,
  idempotent PVC patch. The four states stay exactly the issue's machine.

### D3 — The apply path and the instance status

- **Options**: (a) reuse `Instance :resize` (stopped-first); (b) a new online storage-only
  `:grow_storage` (PVC + quota, no deployment roll except 0→N file-access); (c) require
  the instance stopped.
- **Recommend (b)**.
- **Why**: PVC expansion is a storage-layer capability, not an allocation re-apply; making
  an approved request wait for a customer to stop the instance turns a two-party workflow
  into a three-party chase. The stopped-first ruling belongs to the full re-apply
  (CPU/RAM + deployment), which this path deliberately does not do. The 0→N file-access
  edge re-applies the deployment for the sidecar (the one honest pod roll). #243 narrows
  to CPU/RAM and this becomes its storage arm.

### D4 — Pricing beyond the threshold (owner decision; mechanism tonight)

- **Options**: (a) pass-through + margin; (b) the per-GB curve extended.
- **Recommend (a)**, as a configurable marginal rate above the threshold (provisional
  3¢/GB/mo, marked **PROVISIONAL** in config; COGS floor ≈ 1.4¢/GB at €13/TB ≈ $14.04).
- **Why**: the curve extended is underwater at 1 TB ($12.80 vs $14.04 COGS) and worsens
  with size (2 TB $21.53 vs $28.08; 7.6 TB $58.61 vs $106.70). Pass-through + margin never
  sells below the procurement it triggers, and it is one config line. **The number is
  Terence's morning ratification** — S6 is #250's closer; the mechanism ships now, the
  rate is marked provisional, member copy stays rate-agnostic (it shows the computed
  monthly figure, never the per-GB rule or the COGS), and no business number is in code.

### D5 — Where the operator queue lives

- **Options**: (a) a purpose-built admin Section `/admin/storage-requests`; (b) a
  resource-console leaf under Infrastructure; (c) an Ops-domain resource leaf.
- **Recommend (a)**.
- **Why**: the queue is a decision workflow (approve/reject/retry, capability + wallet
  context), not generic CRUD; the console's settling division is Sections for workflows,
  Resources for raw tables (#595's domain-grouped nav). A generic status edit would
  bypass the apply. The raw `StorageRequest` table stays out of the generic console (a
  read-only note or documented exclusion at Infrastructure's registry intake, forced by
  the parity test).

### D6 — The notification mechanism

- **Options**: (a) in-app PubSub (global queue topic → sidebar badge + live queue);
  (b) operator email via `Mailer`; (c) both.
- **Recommend (a)**.
- **Why**: prod cannot deliver mail (`Swoosh.Adapters.Local`), so email would be a silent
  no-op; the console is the operator's surface, and PubSub is the app's existing
  no-polling mechanism. The badge rides every admin page; the queue re-reads on
  broadcast. Email is a post-prod-mailer follow-up, not a dependency.

### D7 — Billing seam and quote lifetime

- **Options**: (a) snapshot the new total at apply through `PricingSnapshot`
  (create-equivalent, fresh 1-year clock); (b) a separate pass-through overage line that
  reprices with COGS; (c) preserve the old clock and add only the storage delta.
- **Recommend (a)**, with the request's quote **advisory** (apply uses the rates in force
  at approval).
- **Why**: one billing input and one snapshot choice (the #121/#493 contract); a second
  pass-through line is a second ledger path and a second grandfather story. The quote can
  only be advisory while the owner's number is unratified; after ratification the gap is
  negligible. The whole-row clock reset is inherited from resize and stated in the approve
  copy (the instance's new rate is grandfathered for a year).

### D8 — Local acceptance enabler, prod prerequisite, API boundary, runbook home

- **Local**: patch the k3d default StorageClass to `allowVolumeExpansion: true` in the
  local stack (a Tilt custom deploy or a small manifest), because the live cluster
  answers false and the acceptance requires a real growth path. Local-path expansion is
  **spec-level only** (the PV capacity does not move; the host disk is the bound) — the
  acceptance is literally "the PVC spec grew".
- **Prod prerequisite (launch-checklist adjacency, not worker scope)**: the prod
  StorageClass must report `spec.allowVolumeExpansion: true` before any beyond-threshold
  approval can apply. The k3d patch is a local-dev enabler only; if prod's class needs a
  change, that is a launch-checklist item the owner/operator owns — a worker must not
  improvise a prod storage-class change in this lane. The approve action's live probe
  refuses honestly until it is true.
- **API**: member create/list/get ride `instances:read/write`; operator approve/reject/
  retry have no `/api/v1` route (no admin scope). Regenerate `open_api.json` and
  `cargo xtask openapi` in the schema slice.
- **Runbook**: `docs/runbooks/block-storage.md`, internal, outside `docs/public`; never
  linked from user-facing copy; no vendor or cost in any member string.

## 13. Slices (dispatch after the PA go)

Each is one PR referencing #250; the plan doc rides S1. Workers: Synthetic
`syn:large:text`; hostile review fresh-context on Z.AI `glm-5.3` (cross-host rule).
Isolated `MIX_TEST_PARTITION` per lane; reduced parallelism for heavy suites.

- **S1 — pricing mechanism + threshold config + ADR** (independent): the config block,
  `PriceAllocation` marginal term, calibration tests (below/above, threshold parity),
  `docs/pricing-calibration.md` amendment (rule + provisional number), **ADR-0046**
  (storage beyond the threshold: operator queue, online growth, marginal overage rate)
  amending ADR-0043's storage arm and ADR-0028's pricing, and the ADR index row. Small.
- **S2 — StorageRequest domain + API** (after S1): resource, migration, status type,
  state actions, policies, PubSub, JSON:API routes, scope table, open_api.json +
  `cargo xtask openapi`, domain/operation tests. No UI.
- **S3 — Instance `:grow_storage` + apply operation** (can start with S1; independent of
  S2's UI): guard, action, `GrowStorageVolume`, reuse of the resize arms, 0→N
  file-access edge, tests (stubbed K8s spec assertions; PVC spec growth).
- **S4 — member request UI** (after S2): the instance-page card/form/status, preview via
  `ResizePreview`, PubSub re-read, LiveView tests, screenshots (light/dark; a GIF for the
  form → status transition).
- **S5 — operator queue + notification + runbook + local enabler** (after S2 + S3):
  `/admin/storage-requests`, sidebar entry + badge, AdminChrome hook, approve/reject/
  retry operations wired, queue tests, `docs/runbooks/block-storage.md`, docs map, the
  local StorageClass enabler, screenshots (light/dark; a GIF for the badge/queue live
  insert).
- **S6 — ratification (morning, owner)**: the one-line number flip + calibration doc +
  the issue closes. Not dispatched tonight; the mechanism is complete without it.

Dependency note: S3 and S1 can run in parallel; S2 needs S1's config for the quote; S4
needs S2; S5 needs S2 + S3. The architect reviews/merges each arc after green checks +
hostile review (adopt or rebut), rebasing on `main` as lanes land.

## 14. Risks and open questions

- **Stale 400 GB expectation**: recorded in §0; if Terence actually wants 400 GB as the
  boundary, it is the ladder edit + `threshold_gb` in one PR. Not invented here.
- **Local-path is spec-only**: the local acceptance must not be mistaken for real capacity.
  The runbook and the test name say "spec grew"; prod's expandable class is the real gate.
- **Operator misses the badge**: in-app only until the prod mailer; the badge is on every
  admin page, but it is not a phone push. Revisit with the prod mailer (recorded trigger).
- **Two approvals racing the pool ledger**: the queue shows approved-but-unapplied GB; the
  runbook's ledger is manual. A concurrent approval can momentarily exceed the attached
  pool; the capability probe is cluster-level, not per-request. Mitigation in v1: the
  operator's order-before-approve rule + the ledger; a hard reservation is a later lane.
- **Instance deleted mid-queue**: cascade delete takes the request; the approve read fails
  honestly. The member page stops showing the card (instance gone).
- **Self-service resize vs request race**: both use `optimistic_lock(:version)` on the
  instance; the approval re-reads at write time and refuses a stale target.
- **Wallet gate**: the approval requires the org wallet funded (the resize's #124 gate);
  the queue shows the state. Reject-with-feedback is the path for an unfunded org.
- **Pricing number**: the provisional 3¢/GB is a placeholder above the COGS floor, not the
  owner's decision. The morning ratification is the one-line flip; the issue's final
  "pricing rule decided by the owner and implemented" clause closes then.
- **No user cancel**: recorded; a rejected request + re-request is the v1 path.

## 15. Done-when mapping (verbatim)

| Issue's Done when | Where it lands |
|---|---|
| a request beyond the threshold lands in the queue | S2 (create + queue read) + S4 (form) + S5 (queue surface) |
| an operator approve grows the PVC (spec-verified) | S3 (apply, spec assertion) + S5 (approve) |
| reject closes it with feedback to the user | S2 (reject) + S4 (status card) + S5 (reject form) |
| notification fires on new requests (existing operator surfaces) | S2 (PubSub) + S5 (badge + live queue) |
| the runbook page exists for the block-storage order path | S5 (`docs/runbooks/block-storage.md`) |
| PR(s) green | every slice, `mix ci` |
| beyond-threshold pricing rule decided by the owner and implemented | S1 mechanism (tonight) + S6 one-line ratification (morning) |
