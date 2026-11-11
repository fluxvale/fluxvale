# Plan: Operational console — Tier 1 slices + Tier 2 proxy design

Status: **PLAN AT GATE** — waiting on the owner's go (relayed via PA).
Decision record: [ADR-0050](../adr/00050-operational-console.md)
(Proposed). Umbrella: #702. Implementation starts only after the go.

Repo: `fluxvale/fluxvale`, branch off `main`, github-flow; worktree
discipline and the repo AGENTS.md files win wherever they speak.
Every `mix test`/`mix ci` below runs with `MIX_TEST_PARTITION=<lane>`
(#241 — parallel lanes sharing `flux_vale_test` break each other).

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
| W1 | Instance fleet state | `instances` table (`FluxVale.Infrastructure.Instance`) + its paper trail | `Instance |> Ash.Query.for_read(:read, %{}, actor: admin) |> Ash.Query.select([:name, :status, :always_on, :deployed_at])`; deploy rows: `FluxVale.Infrastructure.Instance.Version` (via `FluxValeWeb.AdminAudit.version_module/1`, primary read `:read`) `\|> Ash.Query.filter(version_action_name == :deploy) \|> Ash.Query.sort(version_inserted_at: :desc, id: :desc) \|> Ash.Query.limit(5)`; version chip: `FluxVale.Build.version/0`; env chip: `Application.get_env(:flux_vale, :platform_env)` | probe: filter casts, read executes |
| W2 | Smoke status | GitHub Actions runs of `.github/workflows/smoke.yml` (cron 7,37 * * * *) | `GET https://api.github.com/repos/fluxvale/fluxvale/actions/workflows/smoke.yml/runs?per_page=5` server-side via `Req`, unauthenticated (public repo), 60s cache. Grafana Synthetics: deep-link text only (no in-app seam exists) | live: 1629 runs, latest `success` 06:17 UTC Nov 11 |
| W3 | Wake latency per app (#232) | in-process PromEx histograms `flux_vale_wake_{promotion_wait,app_boot,total}_seconds` (tag `app`) | `FluxVale.Observability.WakeStats` pattern — `PromEx.get_metrics(FluxVale.PromEx)` + bucket walk. Today only the median of total exists (`median_total_by_app_safe/0`); C2 adds p95 of promotion beside it | the median path serves the catalog today |
| W4 | Storage posture | `instances.storage_gb` + the `storage_requests` queue | allocated: Instance read (select `:storage_gb`) + `Enum.sum`; queue counts: `FluxVale.Infrastructure.StorageRequest.queue(%{status: :requested \| :approved \| :applied}, actor: admin)` → `{:ok, page}` → `page.count` (probe: it returns `{:ok, page}`, not a bare page) | probe |
| W5 | Recent audit (summary) | the 31 AshPaperTrail version tables (ADR-0048) | per entry in `FluxValeWeb.AdminAudit.entries/0`: `version_module |> Ash.Query.for_read(:read, %{}, actor: admin) |> Ash.Query.filter(version_inserted_at > ^cutoff) |> Ash.count!()` — 24h per-resource counts, sorted, deep link `/admin/audit` | probe: filter+count executes |
| W6 | Error counts (seam) | none yet — PostHog split (ADR-0049, Proposed, at gate) S1/S4 | `AdminHealth.errors/0` answers `{:error, :not_configured}`; the slot renders the honest placeholder (Grafana Explore `error_signature` is today's surface). Populated via the Tier-2 proxy when the split flips | seam by design, source pending |

Honesty rules every widget obeys: no number without a source; every
derived number names its window ("24h", "since this deployment
started" — the wake series are in-memory and reset on deploy, `PROMEX_ENABLED`-gated).

## Slices (Tier 1)

Order: C1 first (it creates the section every other slice renders
into). C2–C5 each edit `health.ex` and `admin_health.ex`, so they run
sequentially (or rebase each) — append-class conflicts, but flash
workers shouldn't resolve conflicts. All PRs reference #702 without a
closing keyword except the last (C5 closes the umbrella).

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
router comment names it). `AdminShell.groups/0` sections list gains
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

### C3 — storage posture widget

`AdminHealth.storage/1` (actor): allocated GB (Instance select +
`Enum.sum`, comment naming the revisit trigger: an aggregate read
when fleet size makes the wide read matter), queue counts via the
three `StorageRequest.queue/2` calls (pattern-match `{:ok, page}` —
probed), plus a runbook pointer sentence (not a link — the runbook
isn't served). Section renders chips + deep link
`/admin/storage-requests`.
Tests: `admin_health_test.exs` cases with action-created requests
(the `storage_requests` queue tests show the shape).
PR: `feat(platform): storage posture joins the health console`.

### C4 — audit activity widget

`AdminHealth.audit_activity/1` (actor): 24h counts per
`AdminAudit.entries/0` version module (the W5 read), top-5 + total,
deep link `/admin/audit`. Comment: 31 indexed counts per view is fine
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

## Open decisions at the gate

1. **PostHog read-token class.** The insights API needs a
   `phx_`-class personal token; ADR-0049 deliberately keeps those out
   of app/fleet wiring. Either mint a dedicated scoped read token for
   the console (a narrow exception, 1Password-hosted) or the PostHog
   proxy defers until PostHog ships scoped API tokens. No default
   assumed.
2. **Org-runway signal in Tier 1?** `FluxVale.Billing.compute_runway/1`
   exists per-org; a "low-runway orgs" count needs a threshold
   (proposal: 7 days). In or out — owner call.
3. **Nav position.** Health after Audit trail (proposal), and
   `/admin` keeps bouncing to People, not Health.

## Anti-goals for reviewers (do not "fix" these in review)

- The Coming-grammar placeholders (errors, synthetics) are the
  design — an unsourced widget that fabricates is the bug class this
  ADR exists to prevent.
- No new deps anywhere; `Req` only.
- `WakeStats`'s catalog-facing API (`median_total_by_app_safe/0`)
  keeps its exact contract.
- The wake caveat ("since this deployment started") is honesty, not
  a TODO.
