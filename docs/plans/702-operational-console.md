# Plan: Operational console — Tier 1 slices + Tier 2 proxy design

Status: **GO** (owner, Nov 11, 2026, relayed via PA). Decision record:
[ADR-0050](../adr/00050-operational-console.md) (Accepted). Umbrella:
#702. Implementation order C1 → C5; this plan and its ADR landed as
the lane's first PR (#709, opened at the go). Every
`mix test`/`mix ci` below runs with
`MIX_TEST_PARTITION=<lane>` (#241 — parallel lanes sharing
`flux_vale_test` break each other).

## Scope fence — explicitly out of scope

- **Anything dashboard-suite**: funnel builders, ad-hoc query UIs,
  log search, chart editors. The boundary is ADR-0050 D1/D2.
- **Embedding** Grafana or PostHog anywhere — dead on arrival.
- **Tier-2 proxy implementation** — this plan designs it; building it
  is its own gate after Tier 1 ships and proves the section.
- **Tenant-facing panels** — Tier 3 posture note only.
- **A capacity-pool ledger resource** — the runbook stays the source
  of truth; the widget links it by name.
- **Cross-env views, new deps, LiveDashboard changes** — no.
  Everything below uses existing resources, existing modules, and
  `Req` (already a dep).

## The widget contract (surveyed and verified Nov 11)

Every Tier-1 widget, its data source, and the exact read. "Verified"
means executed or probed against the real schema/endpoint today —
probes ran against a partitioned test DB (`MIX_TEST_PARTITION=… mix
run` scratch script, never merged) and live public endpoints.

| # | Widget | Source of truth | Exact read | Verified |
|---|---|---|---|---|
| W1 | Instance fleet state | `instances` table (`FluxVale.Infrastructure.Instance`) + its paper trail | `Instance \|> Ash.Query.for_read(:read, %{}, actor: admin) \|> Ash.Query.select([:name, :status, :always_on, :deployed_at])`; deploy rows: `FluxVale.Infrastructure.Instance.Version` (via `FluxValeWeb.AdminAudit.version_module/1`, primary read `:read`) `\|> Ash.Query.filter(version_action_name == :deploy) \|> Ash.Query.sort(version_inserted_at: :desc, id: :desc) \|> Ash.Query.limit(5)`; version chip: `FluxVale.Build.version/0`; env chip: `Application.get_env(:flux_vale, :platform_env)` | probe: filter casts, read executes |
| W2 | Smoke status | GitHub Actions runs of `.github/workflows/smoke.yml` (cron 7,37 * * * *) | `GET https://api.github.com/repos/fluxvale/fluxvale/actions/workflows/smoke.yml/runs?per_page=5` server-side via `Req`, unauthenticated (public repo), 60s cache. Grafana Synthetics: deep-link text only (no in-app seam exists) | live: 1629 runs, latest `success` 06:17 UTC Nov 11 |
| W3 | Wake latency per app (#232) | in-process PromEx histograms `flux_vale_wake_{promotion_wait,app_boot,total}_seconds` (tag `app`) | `FluxVale.Observability.WakeStats` pattern — `PromEx.get_metrics(FluxVale.PromEx)` + bucket walk. Today only the median of total exists (`median_total_by_app_safe/0`); C2 adds p95 of promotion beside it | the median path serves the catalog today |
| W4 | Storage posture + org runway | `instances.storage_gb` + the `storage_requests` queue + wallet projections | allocated: Instance read (select `:storage_gb`) + `Enum.sum`; queue counts: `FluxVale.Infrastructure.StorageRequest.queue(%{status: :requested \| :approved \| :applied}, actor: admin)` → `{:ok, page}` → `page.count` (probe: it returns `{:ok, page}`, not a bare page); runway: `FluxVale.Billing.Wallet` read (admin actor) + `FluxVale.Billing.compute_runway(wallet)` per wallet, low = float `< :low_runway_hours` (default 168, the owner's gate call) | probe |
| W5 | Recent audit (summary) | the 32 AshPaperTrail version tables (ADR-0048) | per entry in `FluxValeWeb.AdminAudit.entries/0`: `version_module \|> Ash.Query.for_read(:read, %{}, actor: admin) \|> Ash.Query.filter(version_inserted_at > ^cutoff) \|> Ash.count!()` — 24h per-resource counts, sorted, deep link `/admin/audit` | probe: filter+count executes |
| W6 | Error counts (seam) | none yet — PostHog split (ADR-0049, Proposed, at gate) S1/S4 | `AdminHealth.errors/0` answers `{:error, :not_configured}`; the slot renders the honest placeholder (Grafana Explore `error_signature` is today's surface). Populated via the Tier-2 proxy when the split flips | seam by design, source pending |

Honesty rules every widget obeys: no number without a source; every
derived number names its window ("24h", "since this deployment
started" — the wake series are in-memory and reset on deploy, `PROMEX_ENABLED`-gated).

## Slices (Tier 1)

Order: C1 first (it creates the section every other slice renders
into). C2–C5 each edit `health.ex` and `admin_health.ex`, so they run
sequentially (or rebase each) — the collisions are append-class, but
nobody should be resolving conflicts in a shared file. All PRs
reference #702 without a closing keyword except the last (C5 closes
the umbrella).

### C1 — the section + fleet widget

New `apps/platform/lib/flux_vale_web/admin_health.ex`
(`FluxValeWeb.AdminHealth`, the `AdminAudit` web-side-assembler
precedent) with `fleet/1` (actor) returning the W1 map: env, version,
per-status counts (`FluxValeWeb.InstanceStatus.label/1` renders),
always_on count, 5 recent deploys (`version_source_id` short UUID via
`FluxValeWeb.AdminResource.short_uuid/1`, `actor_label`, timestamp).
New `apps/platform/lib/flux_vale_web/live/admin_live/health.ex`
(`FluxValeWeb.AdminLive.Health`) — `Layouts.app … bare wide` +
`AdminShell.sidebar current="health"`, mount reads
`AdminHealth.fleet(socket.assigns.current_user)`. Router: one `live
"/health", FluxValeWeb.AdminLive.Health` line in the `:admin`
live_session, before the generated-tool mounts (source-order hazard,
router comment names it). The private `groups` list inside
`FluxValeWeb.AdminShell` (it is `defp` — there is no public
`AdminShell.groups/0` to call) gains
`%{key: "health", label: gettext("Health"), path: ~p"/admin/health"}`
after the audit entry.
Tests: `test/flux_vale_web/admin_health_test.exs` (fleet shape with
action-created instances; deploy rows — `Ash.seed!` the Version
resource with a why-comment: the `:deploy` action enqueues k8s/Oban
work a unit test must not run; if the generated create rejects the
attrs, report, don't hack) and `test/flux_vale_web/admin_health_live_test.exs`
(admin sees the section; non-admin bounces — mirror
`admin_people_live_test.exs`).
PR: `feat(platform): /admin/health — console section + instance fleet widget`.
Done when: `MIX_TEST_PARTITION=oc-c1 mix ci` green; both new test
files' cases pass by name in the transcript.

### C2 — wake widget

Extend `FluxVale.Observability.WakeStats` (public API for the catalog
untouched): add `@promotion_bucket_prefix
"flux_vale_wake_promotion_wait_seconds_bucket{"`, hold both maps in
the cache state (`%{computed_at, medians, p95_promotions}`), public
`p95_promotion_by_app/0` + `_safe/0` (same `@min_samples` guard,
quantile 0.95 via the existing `quantile/2` walk). `AdminHealth.wake/0`
wraps the two safe calls; the section renders the per-app table
(p95 promotion, median total) + the "since this deployment started"
caveat.
Tests: extend `test/flux_vale/observability/wake_stats_test.exs`
mirror-shape (`:telemetry.execute([:flux_vale, :wake, :promotion], …)`
+ `start_supervised!(FluxVale.PromEx)`), plus the live section.
PR: `feat(platform): wake p95 joins the health console (#232 series)`.

### C3 — storage posture + org-runway widget

`AdminHealth.storage/1` (actor): allocated GB (Instance select +
`Enum.sum`, comment naming the revisit trigger: an aggregate read
when fleet size makes the wide read matter), queue counts via the
three `StorageRequest.queue/2` calls (pattern-match `{:ok, page}` —
probed), plus a runbook pointer sentence (not a link — the runbook
isn't served). Section renders chips + deep link
`/admin/storage-requests`.
`AdminHealth.runway/1` (actor) — the owner's gate call (Nov 11):
`AdminHealth.runway/1` (actor) — the owner's gate call (Nov 11): wallets via `FluxVale.Billing.Wallet |> Ash.Query.for_read(:read, %{}, actor: actor) |> Ash.read!()` (the billing section's wallet read, minus its `:balance` load — the projection reads the balance itself); org names resolve through the flagged `Organization :admin_lookup` seam exactly as the billing section does (NOT a `load(:organization)` off the wallet — the billing surface deliberately never reads that relationship). Then `FluxVale.Billing.compute_runway(wallet)` per wallet (billing.ex:89 defdelegate). The honesty rule, up front: `:infinity` runway is never low; a float below `Application.get_env(:flux_vale, :low_runway_hours, 168)` is low; an `{:error, _}` projection counts as "unknown" and renders as its own count — never hidden, never zero. Renders the low-runway list (org name + hours) + a deep link `/admin/billing`. Comment: per-org projection reads instances per wallet — fine at beta scale, revisit with a cache if it profiles.
Tests: `admin_health_test.exs` cases with action-created requests
(the `storage_requests` queue tests show the shape) driving the three
counts; runway cases — a wallet under threshold (create org + wallet
through actions, seed a balance if the actions can't produce one,
with a why-comment), a burn-free wallet (runway `:infinity`, never
low), the threshold override arm. Live test: chips render.
PR: `feat(platform): storage posture and org runway join the health console`.

### C4 — audit activity widget

`AdminHealth.audit_activity/1` (actor): 24h counts per
`AdminAudit.entries/0` version module (the W5 read), top-5 + total,
deep link `/admin/audit`. Comment: 32 indexed counts per view is fine
at beta scale; a TTL cache is the revisit if it ever profiles.
Tests: version rows fabricated through real actions (the
`admin_audit_live_test.exs` `versions!/2` pattern).
PR: `feat(platform): 24h audit activity joins the health console`.

### C5 — smoke status widget + the error seam

New `apps/platform/lib/flux_vale/observability/smoke_runs.ex`
(`FluxVale.Observability.SmokeRuns`, the WakeStats GenServer shape):
60s TTL (`:smoke_runs_ttl_seconds` app env), `Req.request([url:
@runs_url, headers: [accept: "application/vnd.github+json"]] ++
Application.get_env(:flux_vale, :smoke_runs_req_options, []))` — the
app-env req options are the test seam (`plug: {Req.Test, :smoke_runs}`);
public `latest/0` → `{:ok, %{runs: [...], fetched_at: ...}}` |
`{:error, :unreachable}`, plus `_safe/0`. Supervision tree: beside
`WakeStats` (application.ex). `AdminHealth.errors/0` →
`{:error, :not_configured}`. Section renders: latest verdict chip +
last-run time + public runs link
(`https://github.com/fluxvale/fluxvale/actions/workflows/smoke.yml`),
and the errors placeholder (ADR-0050 D6 copy).
Tests: `test/flux_vale/observability/smoke_runs_test.exs`
(`Req.Test.stub(:smoke_runs, fn conn -> … end)` serving canned JSON;
unreachable arm), live section + placeholder.
PR: `feat(platform): smoke verdicts + the error-tracking seam join
the health console` — **closes #702**.
Done when (umbrella): all slices merged; `/admin/health` renders all
six surfaces on staging; every unsourced slot says so in place.

## Tier 2 — proxy design (build later, own gate)

Two server-side readers, same skeleton as WakeStats (named GenServer,
30–60s TTL, safe fallback that renders "unavailable", never raises):

- **PostHog insights** (product widgets: signups, active orgs,
  deploys/day): curated insights created in the PostHog UI by the
  owner, referenced by id — `GET
  https://eu.i.posthog.com/api/projects/<id>/insights/<insight_id>`
  (probed: endpoint live, 403 unauthenticated), Bearer read token.
  The console renders numbers, never the insight.
- **Grafana hosted Prometheus** (infra metrics: PG connections, Oban
  depth, CNPG backup age — the alert set's raw series): `POST
  https://prometheus-prod-65-prod-eu-west-2.grafana.net/api/prom/api/v1/query`
  (probed: 401 unauthenticated; `/api/v1/query` is 404 — the
  `/api/prom` prefix is the path), basic auth username + access-policy
  token.

Hard rules (ADR-0050 D4): tokens only in server env, sourced from
1Password items through the fleet (ADR-0021 Am. 3 flow — today these
creds exist only as GitHub secrets, so env wiring is fleet-repo work
when this gate opens); a fixed whitelist of named queries in a
registry module — no endpoint accepts a caller-supplied query; one
refresh a minute at most, per-widget; the browser payload is
computed numbers only.

## Tier 3 — posture note

Tenant-facing health panels (an org seeing its own instances' state,
backup freshness, wake times) are a future product decision: org-
scoped, server-side, own data only, never cross-org aggregation —
and explicitly not this lane. Surfaced here so nobody reads this
console as the tenant product's beginning.

## Gate calls (owner, Nov 11, 2026 — resolved, no longer open)

1. **PostHog read-token class → DEFERRED.** The Tier-2 PostHog
   insights proxy rides the PostHog split's S1/S4 landing (that lane
   received its go the same morning; the interlock sequences itself).
   The Grafana Prometheus proxy design stands as written and stays
   gated behind Tier 1 either way.
2. **Org-runway signal → IN.** "Low-runway orgs" joins C3 at a 7-day
   threshold, configurable via app env (`:low_runway_hours`, default
   168).
3. **Nav → as proposed.** Health sits after Audit trail; `/admin`
   keeps bouncing to People.

## Anti-goals for reviewers (do not "fix" these in review)

- The in-place placeholders (errors, synthetics) render their
  not-configured state honestly — that IS the design; an unsourced
  widget that fabricates is the bug class this ADR exists to prevent.
- No new deps anywhere; `Req` only.
- `WakeStats`'s catalog-facing API (`median_total_by_app_safe/0`)
  keeps its exact contract.
- The wake caveat ("since this deployment started") is honesty, not
  a TODO.
