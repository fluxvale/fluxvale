# ADR-0049: Observability split — PostHog for the app surface, Grafana for the floor

**Status**: Proposed (owner-decided 2026-11-11, account created; flips to
Accepted when Phase 1 lands)
**Date**: 2026-11-11

**Decision**: product analytics, error tracking, and app traces gain a
second home in **PostHog Cloud EU**; Grafana Cloud keeps what PostHog
cannot do (Prometheus metrics, synthetics) and what it should not do
yet (logs). [ADR-0012](00012-observability-grafana-cloud.md)'s
Alloy→Grafana spine is untouched — this adds a vendor beside it, it
does not replace it. Five decisions, all owner-settled:

1. **Product analytics + error tracking + app traces move to PostHog.**
   Nothing exists today on the analytics side (the space is empty); the
   core-team-maintained Elixir SDK (`posthog` Hex package, error
   tracking on by default via a Logger handler — crash reasons always,
   other messages at `capture_level`, default `:error`) retires the
   "no Sentry-grade Elixir client" concern and delivers the issue inbox
   [ADR-0012](00012-observability-grafana-cloud.md) Am. 2 said earns a
   subscription at error *volume* — free at our scale. **This resolves
   [ADR-0016](00016-deferred-triggers.md)'s triage-volume trigger by
   adopting PostHog instead of Honeybadger/AppSignal.** Traces move by
   **Alloy dual-export** (the app's existing OTLP emission, a second
   `otelcol.exporter.otlphttp` block beside Tempo): Tempo keeps full
   history; PostHog gains person/session correlation — the one thing
   Tempo can't do.
2. **Metrics + synthetics stay on Grafana.** PostHog metrics is an open
   alpha ("may change before general availability", 30-day retention,
   no alerting parity); there is no synthetics product at all (their
   issue #31488). PromEx + hosted Prom + Grafana Synthetics keep their
   load-bearing jobs exactly as-is; revisit metrics at PostHog GA.
3. **Logs are Phase 3, not now.** Grafana free = 50 GB logs with long
   retention vs PostHog 10 GB **shared** logs+traces with 14-day
   retention; the stdout-JSON→Alloy path is battle-tested
   ([observability.md](../observability.md)'s emission rule). Phase 3,
   only if Phases 1–2 stick, decides by amendment — same Alloy fan-out
   shape, so no wiring is lost by waiting.
4. **Session replay is OFF at launch.** posthog-js ships with recording
   on — it is disabled day one. Replay is the only part that records
   screen content and the biggest cost lever (unsampled at 10k MAU
   ≈ $170/mo; sampled 20% ≈ $25). A later toggle is its own arc:
   sampling config, masking on, its privacy-policy sentence, and a
   cost check against real traffic.
5. **Self-hosted Umami is kept; region EU; IP capture off.** Public
   pages stay Umami (traffic counts, dogfood proof of bundled backing
   services); PostHog runs inside the signed-in app only — layered, not
   migrated. EU (Frankfurt) at signup is the simpler GDPR posture for
   EU visitors (PostHog EU disables IP capture by default for new
   projects); a persistent bootstrapped distinct ID is still personal
   data, named in the policy.

**Cookieless posture** (the "we run no tracker we do not own" promise
gets a named exception): in-app posthog-js runs `persistence: "memory"`
with the server bootstrapping `distinct_id` from the signed-in session
— no cookies, no localStorage, nothing written to the visitor's device;
person profiles are suppressed. The **privacy-policy update rides the
same arc** (the Nov 5 standing obligation: name the tool, what it
collects, cookieless or not) — it lands before any environment flips
on.

**Cost basis** (free allowances reset monthly: 1M analytics events,
100k exceptions, 10 GB logs+traces, 5k replays; each product has an
independent billing limit that *stops ingestion* — set to $0 on
analytics + replay from day one until the Busy scenario is real):

| Scenario (signed-in MAU) | PostHog | Grafana |
|---|---|---|
| Launch ~100 | **$0** (~14k events, 0.2% of exceptions) | $0 |
| Growing ~1k | **$0** (~120k events; replay would sit at the line — it's off) | $0 |
| Busy ~10k | **~$35/mo** (~$10 with replay off: $5 analytics overage + Phase-3 traces if any; replay sampled 20% adds $25) | $0 |

The real cost is the second vendor surface (policy, region, two
dashboards), not dollars.

**Revert posture — every phase independently revertible:**

- Phase 1 (SDK + client analytics + policy): kill switch = the single
  env var `POSTHOG_API_KEY` unset or empty — the SDK supervision tree
  and Logger handler never start, the client renders nothing at all.
  Code lands inert; the flip is staging-then-prod by env wiring alone.
- Phase 2 (trace dual-export): delete one exporter block + one fan-out
  edge in the fleet Alloy config; the app binary is unchanged. Unlike
  Phase 1 it is cluster-wide (one Alloy serves both envs) — the
  mitigation is the instant revert plus the $0 billing limit.
- Phase 3 (logs): never moves unless a future amendment says so;
  Grafana ingestion never stops.

**Rejected alternatives**:

- *Everything to PostHog* — capability loss on the two load-bearing
  Grafana jobs (metrics maturity, synthetics existence).
- *Grafana-only status quo* — no product analytics at all, and error
  triage stays LogQL-only at exactly the scale where ADR-0012 Am. 2
  deferred the issue inbox.
- *Amending ADR-0012 in place* — owner chose a new ADR: this adds a
  vendor rather than overturning the Grafana decision; ADR-0012 gets a
  pointer amendment (Am. 4) instead.
- *Self-hosted PostHog* — ADR-0012's decisive argument (an observatory
  on the observed box is blind exactly when it matters) applies
  unmodified.
- *Sentry/Honeybadger/AppSignal subscription* — ADR-0016 deferred it
  to a volume trigger; PostHog's free tier delivers the inbox now.
- *PostHog feature flags / AI observability* — **not adopted**, flagged
  here so neither arrives by drift: the in-app Ash FeatureFlag
  evaluator
  ([ADR-0023](00023-day-one-gates.md)) stays; there is no LLM feature.
  Revisit flags only as a deliberate ADR.

**Secrets**: one value — the `phc_` **project** token (public by
design; client libs use it) — per-env in 1Password via the fleet's
references-only flow ([ADR-0021](00021-secrets-bws-operator.md) Am. 3),
never in either repo. The `phx_` personal API token stays owner-side
for account operations and never enters fleet or app wiring.
**Staging-first at the account level too** (owner ruling 2026-11-11,
confirmed EU): the free tier (no card yet) allows a single project —
"FluxVale - Staging" — so staging runs there; production gets its own
project when billing is added (an account step, not a technical one),
and the prod 1Password item stays empty until that project's key
exists. Until then the `$host` event property keeps envs
distinguishable inside the one project; after the split they are
separate projects outright.

Implementation plan (slices S0–S6, rollout order, operator checklist):
[../plans/posthog-observability-split.md](../plans/posthog-observability-split.md).
