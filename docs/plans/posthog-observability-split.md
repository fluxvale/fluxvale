# Plan: PostHog observability split — Phase 1 + Phase 2 slices

Status: **ACCEPTED — go relayed 2026-11-11** (implementation in flight,
slices in order; the prod flip is deferred with the prod project, so
Phase 2's "Phase 1 verified" gate means *staging* verification).
Decision record: [ADR-0049](../adr/00049-posthog-app-observability-split.md)
(Proposed; flips to Accepted when Phase 1 lands).

Repos: **app** = `fluxvale/fluxvale` (branch off `main`, github-flow),
**fleet** = `fluxvale/infrastructure` (private, same flow). Worktree
discipline and the repo AGENTS.md files win over this plan wherever
they speak.

## Scope fence — explicitly out of scope

- **Logs** — Phase 3, its own gate after Phases 1–2 stick; no wiring now.
- **Metrics / synthetics** — stay on Grafana; zero work.
- **Session replay** — OFF (disabled in client config day one); the
  later toggle is its own arc (sampling + masking + policy sentence +
  cost check).
- **Umami** — untouched; public pages keep it.
- **PostHog feature flags, AI observability** — not adopted
  (ADR-0049's rejected-alternatives list names them so they don't
  arrive by drift).

## Secrets / config shape (all slices read this)

One gate, one value, one flow:

- **`POSTHOG_API_KEY`** is the only env var. It carries the `phc_`
  **project** token (public by design — client libs use the same
  token). Unset or `""` (the classic empty-Secret shape) = everything
  off, structurally: no SDK supervision tree, no Logger handler, the
  client renders nothing at all.
- **Host is a config default, not an env var**: `https://eu.i.posthog.com`
  (EU decision, ADR-0049) baked into the app's PostHog config
  resolution. The client reads it from the server-rendered hook.
- **Where the value lives**: 1Password, per-env vaults
  (`fluxvale-staging`, `fluxvale-production`), item `posthog-api-key`,
  tofu-owned (`tofu/onepassword-items.tf`, values only through the
  seed script's write-only fields — the ADR-0021 Am. 3
  references-only flow). Never in either repo. The staging item is
  already filed by the owner (2026-11-11); **verify its field
  category at wiring time with a read attempt before assuming the
  rendered Secret key** — password-category items read `password`,
  login-category read `credential` (an owner-stack lane finding) — and
  pin what the read proves in S4's PR. **One project for now**
  (owner ruling): the free tier's single project is "FluxVale -
  Staging"; the prod item stays **empty** until production gets its
  own project at billing setup (an account step, not a technical one)
  — the prod flip seeds the prod item with the *production project's*
  key, never a copy of staging's. `$host` separates envs inside the
  one project meanwhile. No rotation coupling beyond each item itself.
- **The `phx_` personal API token never enters fleet or app wiring** —
  owner-side only, for account-level operations.
- **Rollout**: code lands flag-off (no env set anywhere) → flip
  staging (seed the staging item, restart the staging rollout) →
  verify → flip prod (fill the prod item, restart). Every flip is
  value-only; every revert is unset.

## Owner checklist (account setup — mostly done)

Confirmed by the owner (2026-11-11): region **EU** (ingestion host
`https://eu.i.posthog.com`), the single free-tier project named
"FluxVale - Staging", and the staging `phc_` token filed to 1Password
(`fluxvale-staging` vault, `posthog-api-key` item — its field category
is verified at wiring time, not assumed). Still to verify at kickoff:
**IP capture off** (EU default for new projects — confirm in project
settings) and **billing limits set to $0** on analytics + replay
(independent hard stops per product). Deferred until billing setup
(owner, no code): the **production project** — its key seeds the prod
1Password item and flips prod; until then the item stays empty.

## Slices

Order: S0 → S1 → S1b → (S2 ∥ S3) → S4 (staging flip → verify; the prod
flip waits for the production project at billing setup). Phase 2 after
Phase 1 is **staging**-verified: S5 → S6. Umbrella issues open at the
go (one per phase, referencing ADR-0049 + this plan); slice PRs
reference the umbrella without a closing keyword — except S3 (closes
the Phase 1 issue) and S6 (closes Phase 2).

### S0 (app) — decision record

ADR-0049 + index row + ADR-0012 Am. 4 pointer + the observability.md
"decided, not yet running" note — all four in one docs-only PR
(`docs: ADR-0049 the PostHog observability split (proposed)`). This
plan file and the ADR are already drafted on `feat/posthog-split`;
the PR opens at the go with any wording fixes from the review.

Done when: `cd apps/platform && mix ci` green, and
`grep -c "00049-posthog" docs/adr/README.md` prints `1`.

### S1 (app) — Elixir SDK: error tracking + identity, off by default

Files and shape (mirror the patterns named in app AGENTS.md):

- `apps/platform/mix.exs`: `{:posthog, "2.20.1"}` exact pin (latest
  stable as of 2026-11-11 — re-verify on hex.pm at implementation and
  pin whatever is current; comment: ADR-0049, error tracking + product
  events).
- `apps/platform/config/config.exs`: `config :posthog, enable: false`
  — we own the supervisor (the SDK's advanced pattern), so the kill
  switch is structural, not a flag deep in the SDK. Also set the
  source-context keys here (`enable_source_code_context: true`,
  `root_source_code_paths: [File.cwd!()]`, `context_lines: 5`) — the
  packaging mix task reads them at build time; verify the task's
  config source (app env vs `:posthog` env) against the installed
  version and adjust so the keys are where it looks.
- `apps/platform/lib/flux_vale/observability.ex`: add
  `posthog_config/0` — `POSTHOG_API_KEY` nil/`""` → `:unset`; a value
  → `{:ok, %{api_host: "https://eu.i.posthog.com", api_key: value,
  in_app_otp_apps: [:flux_vale], capture_level: :error, metadata:
  [:request_id] ++ source-context keys}}`. The
  `FluxValeWeb.SiteAnalytics.from_env/2` shape: one answering module,
  runtime.exs stays thin, the resolution is unit-testable.
- `apps/platform/config/runtime.exs` (test excluded, the UMAMI
  stance): resolve `posthog_config/0`; `{:ok, cfg}` → `config
  :flux_vale, :posthog, cfg`; `:unset` → leave absent. Never warn,
  never block boot — unset is the deliberate default everywhere.
- `apps/platform/lib/flux_vale/application.ex`: when `:posthog`
  config present — `cfg |> PostHog.Config.validate!()` then children
  gain `{PostHog.Supervisor, cfg}` (beside the `prom_ex_child/0`
  pattern) and boot adds `:logger.add_handler(:posthog,
  PostHog.Handler, %{config: cfg})`. Absent → no child, no handler.
  Oban failures already log at ERROR, so they flow in automatically.
- `apps/platform/lib/flux_vale_web/endpoint.ex`: before `plug
  FluxValeWeb.Router`, plug `FluxValeWeb.Plugs.PostHogRequestContext` —
  a thin wrapper (hand-written glue comment why): conn untouched when
  `:posthog` config absent; otherwise `PostHog.Integrations.Plug`
  (attaches URL/host/path/IP context, reads
  `X-PostHog-Distinct-Id`/`-Session-Id`).
- Router `:browser` pipeline, after `MaybeResolveUser`:
  `plug FluxValeWeb.Plugs.PostHogIdentity` — no-op when config absent
  or no resolved user; otherwise `PostHog.set_context(%{distinct_id:
  user.id})` (process-scoped: request-process errors and captures get
  the id). LiveView processes do not inherit it — server events
  outside requests pass `distinct_id` explicitly (S1b). API pipeline
  stays identity-less for now (its errors land as "unknown" — noted,
  acceptable).
- `apps/platform/Dockerfile`: `RUN mix posthog.package_source_code`
  immediately before the existing `RUN mix compile && mix
  assets.deploy && mix release` (line ~53) so stack frames render with
  source context in the PostHog UI.

Tests (no network — nothing starts when unset; the configured path is
exercised through `PostHog.Config.validate!/1` on the resolved map,
which is pure): `posthog_config/0` unset/value/empty-string arms;
application-tree child absent without config (the `prom_ex_child`
test pattern); wrapper plug pass-through/set arms; identity plug
set/no-user arms. Coverage 100% by the repo's exclusion discipline.

PR: `feat(platform): PostHog server SDK — error tracking, gated off by
default`. No behavior anywhere until S4 sets env. Evidence: `mix ci`
green transcript.

### S1b (app) — server-side product events

- `apps/platform/lib/flux_vale/analytics.ex`: facade
  `capture(event, distinct_id, props \\ %{})` — no-op when `:posthog`
  config absent; otherwise `PostHog.capture/2`. Event names in the
  SDK's `[object] [verb]` convention.
- Call sites, four launch events: `instance deployed`,
  `instance wake triggered`, `wallet topped up`, `org member invited`
  — at the operation that owns each flow (the domain operations under
  `lib/flux_vale/contexts/*/operations/`), passing the acting user's
  id as `distinct_id` explicitly. `apps/platform/test` mirrors.
- Tests: facade no-op/configured arms (gate logic only; the
  capture-through is asserted against a fake capture function or the
  SDK's test mode — verify what the installed version offers and use
  it; no live network in the suite).

PR: `feat(platform): server-side product events via PostHog
(instance/wallet/invite)`.

### S2 (app) — in-app client analytics (cookieless)

- Vendor the SDK: `apps/platform/assets/vendor/posthog-js.js` — the
  dist module build at an exact version (current stable at
  implementation; record version + source URL + license in the file
  header, the `topbar.js` pattern). No npm/Node enters the repo
  (the esbuild-is-a-Hex-binary rule); the vendor import satisfies the
  app.js-bundle-only rule, so **no second cross-origin-script
  exception** is created.
- `apps/platform/lib/flux_vale_web/components/app_analytics.ex`:
  `FluxValeWeb.AppAnalytics` (the SiteAnalytics sibling, inverted:
  server-known config, no external script). Reads `:posthog` config at
  render time; renders **nothing at all** when unset; otherwise a
  single hidden hook element inside the app layout —
  `<div id="posthog-config" data-api-host="…" data-api-key="…"
  data-distinct-id="…" hidden>` — `data-distinct-id` only when a user
  is signed in.
- `apps/platform/lib/flux_vale_web/components/layouts.ex`: render the
  hook from `app/1` **only** (`current_user` attr supplies the id).
  Never from `public/1`, the landing page, or email layouts — public
  stays Umami (ADR-0049's layering).
- `apps/platform/assets/js/app.js`: read the hook at boot; absent →
  never init (no network, the whole feature). Present → `posthog.init`
  with the cookieless posture from ADR-0049: `persistence: "memory"`,
  bootstrapped `distinct_id` from the hook, `person_profiles:
  "never"`, session recording **disabled**, `tracing_headers`
  targeting our own backend (sends `X-PostHog-Distinct-Id`/
  `-Session-Id` on app requests — the S1 plug reads them), autocapture
  default (clicks/pageviews; form values are not captured by default —
  keep it that way). LiveView pageviews: verify
  `history_change`-based capture fires on pushState navigations with
  the vendored version; if not, add the documented
  `phx:navigate → $pageview` listener. **Verify every option name
  against the vendored version's config docs** (posthog.com/docs/libraries/js
  — the options move); the posture above is the contract, the key
  names are the version's.
- Tests: component renders nothing when unset / the hook with attrs
  when set / no distinct_id when anonymous (the SiteAnalytics test
  pattern); `mix ci` includes the esbuild bundle leg (app.js compiles).
- Captures (repo screenshot rule; nothing here is visual UI — the
  honest capture is the DOM hook): devtools element panel before/after
  (env set via `POSTHOG_API_KEY=phc_dummy mix phx.server` — the client
  will attempt calls to the EU host with a dummy token; that is
  harmless and does not leave the machine beyond a failed ingest), or
  the network panel showing zero requests when unset. Embed per the
  absolute-URL rule.

PR: `feat(platform): in-app product analytics via PostHog (memory
persistence, gated off by default)`.

### S3 (app) — privacy-policy rider (the standing obligation)

The Nov 5 obligation: name the tool, what it collects, cookieless or
not — **lands before any env flip** (S4 ordering).

- `apps/platform/lib/flux_vale_web/controllers/policy_html/privacy.html.heex`:
  replace the "What we never collect" card copy and add one sentence
  to "Logs and monitoring" naming PostHog as a second processor for
  product analytics and error reports (Grafana stays named). Starting
  copy (final wording follows the page's copy rules — plain sentences,
  no em-dashes, no semicolons; keep the structure the existing tests
  assert):

  > We measure how the product is used with PostHog, an analytics
  > service run by PostHog Inc. Inside the signed-in app it records
  > which pages you open and which buttons you press, and it collects
  > errors you hit so we can fix them. It sets no cookies and stores
  > nothing on your device. We do not let it read the data inside your
  > instances. No advertising trackers ride our pages.

  (The card's other promises — no selling, no profiling — stay.)
  Bump the page's "Last updated" date. The **traces** sentence rides
  S6 (Phase 2), so the page stays truthful at every point in time.
- Tests: update the policy content assertions (existing pattern).

PR: `docs(platform): privacy policy names PostHog (analytics + error
tracking, cookieless)` — opens with `Closes #<phase-1-umbrella>`.
Captures: before/after, light+dark (public page, user-visible).

### S4 (fleet) — env wiring + the flips

- `tofu/onepassword-items.tf` `password_items`: add
  `"fluxvale-staging/posthog-api-key"` and
  `"fluxvale-production/posthog-api-key"` (titles `posthog-api-key`;
  **separate values** — staging's project now, production's own
  project later; the empty-prod guard below covers the gap).
- `apps/staging/onepassworditem-posthog.yaml` +
  `apps/production/onepassworditem-posthog.yaml` (the polar-file
  pattern): CR `posthog-api-key`, `itemPath` into each env vault.
  **First wiring step: a read attempt against the staging item to
  pin its field category** — password-category renders Secret key
  `password`, login-category renders `credential` (an owner-stack
  lane finding; do not assume). The `secretKeyRef.key` below and any
  docs note carry the proven key.
- `apps/base/deployment.yaml` env anchor: `POSTHOG_API_KEY`
  `secretKeyRef: posthog-api-key / <proven key>`. **Both-envs trap**:
  the anchor flips both envs — the prod item must exist from this PR
  on. Preferred shape: prod item seeded **empty** from day one (the
  app treats `""` as unset — inert until the flip fills it). If the
  seed script rejects empty values (verify
  `scripts/onepassword-seed.sh`), fall back to: staging overlay
  carries the env var, moved into the base anchor at the prod flip.
  Either way staging-first holds.
- Flips (value-only, after S1+S2+S3 are merged): the staging item is
  already filed by the owner — the staging flip is this PR landing
  (CR renders the value) + `kubectl -n fluxvale-staging rollout
  restart deploy/fluxvale-platform` → verify. The **prod flip waits
  for the production project** (owner creates it at billing setup):
  seed the prod item with *that project's* key → restart prod.
- Verify at each flip (evidence for the report): staging — PostHog
  Live events show `$pageview` from a staging browse and a
  `$exception`/error event from a deliberate `Logger.error` via
  `bin/rpc`/IEx on the staging pod; `/health` stays green; with env
  unset (pre-flip) the rendered app HTML contains no `posthog-config`
  hook. Screenshots of the PostHog UI events embedded in the PR.

PR (infrastructure): `apps: POSTHOG_API_KEY env wiring (1Password,
staging-first)`. Revert = unset the item value + restart (the app
code stays, inert).

### S5 (fleet) — Alloy trace dual-export (Phase 2 opener)

- `cluster/monitoring/install/alloy.yaml`: add
  `otelcol.exporter.otlphttp "posthog_traces"` beside the existing
  `tempo` exporter: full traces endpoint
  `https://eu.i.posthog.com/i/v1/traces` — **path-append trap**: the
  exporter appends its own path segments to a configured base
  `endpoint` (the Tempo gateway block in this same file relies on
  that), so either use the per-signal full-URL option (`traces_endpoint`
  if the pinned Alloy supports it — verify against the running
  version) or set `endpoint` to the base that makes the append land on
  `/i/v1/traces` exactly. Auth: `Authorization: Bearer <phc_ token>`
  header from `sys.env("POSTHOG_API_KEY")` (env reaches Alloy the same
  way the `gc_*` values do — follow their item/CR pattern in the
  monitoring tree for the token's 1Password item).
  Fan-out: the existing batch processor's `output.traces` gains
  `otelcol.exporter.otlphttp.posthog_traces.input` beside the tempo
  input. **Nothing else changes** — redaction stays upstream of the
  batch (so PostHog gets the same credential-scrubbed spans as
  Tempo), Tempo never stops.
- **Cluster-wide by construction** (one Alloy serves both app envs —
  no staging-first split for traces without an app-side resource
  attribute; not worth one). **One-project consequence**: until the
  production project exists (billing setup), prod and staging traces
  alike land in the "FluxVale - Staging" project — accepted with the
  go (traces are internal, redacted telemetry; revert is one block;
  the $0 billing limit caps the meter). Mitigation: the instant
  revert (delete the exporter + the fan-out edge) and the $0 billing
  limit.
- Evidence: PostHog traces tab shows fresh app spans (screenshot);
  the same span still queries in Tempo via Grafana Explore
  (screenshot or query URL). App binary unchanged.

PR (infrastructure): `monitoring: dual-export app traces to PostHog
(Tempo kept)`.

### S6 (app) — person/session context on spans + traces policy line

- `apps/platform/config/runtime.exs` (the OTel block): when both the
  OTLP exporter is on and `:posthog` config is present, prepend
  `{PostHog.OpenTelemetry.ContextSpanProcessor, %{supervisor_name:
  PostHog.Supervisor-name}}` to the processors list (verify the exact
  supervisor name arg from the installed SDK docs) — stamps
  `posthog.distinct_id`/session ids from process context onto spans.
  **Bandit caveat, recorded in a comment with its revisit trigger**:
  the request-span header linkage is documented for Cowboy and
  unverified with Bandit — correlation lands on child spans
  (Ecto/custom in-process), not the request span, until the bandit
  adapter supports header capture. Oban workers that capture product
  events (S1b) set `PostHog.set_context` at job start so their spans
  correlate too — add that line beside each S1b call site if the
  worker's spans are the ones that matter (deploy/reconcile).
- Privacy page: the one-sentence addition to "Logs and monitoring"
  naming traces (S3 left it out on purpose).
- Tests: processor config resolution arms (present/absent ×
  exporter on/off — the Observability test pattern); policy content
  assertion updates.

PR: `feat(platform): person/session context on spans
(PostHog ContextSpanProcessor)` — closes the Phase 2 umbrella issue.

## Anti-goals for reviewers (do not "fix" these in review)

- The Umami cross-origin exception stays exactly one; PostHog is
  bundled, never a script tag.
- `enable_error_tracking` stays at its default (true when configured)
  — the Logger handler IS the error-tracking decision (ADR-0049 D1).
- No OTLP log-push from Elixir, ever (observability.md emission
  rule) — logs are Phase 3 and even then they ride Alloy.
- No feature-flag reads, no `person_profiles` flip, no replay
  enablement — all named in ADR-0049's rejected list.
