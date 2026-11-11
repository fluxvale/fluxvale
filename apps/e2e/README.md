# FluxVale e2e

Playwright suite ([ADR-0024](../../docs/adr/00024-e2e-review-environments.md)). Four runtimes share it — local, review
environments, staging, and prod (read-only subset) — selected entirely
via `BASE_URL`. The suite never starts a server; point it at one.

## Setup

```sh
npx playwright install chromium   # browser binaries (once per machine)
```

Node comes from the repo's mise config (`mise install` at the root).

## Run locally

The suite expects the k3d stack running, seeded, and a TestInbox PAT
in hand. `scripts/e2e-bootstrap.sh` (repo root) does all of it —
cluster + charts + manifests + dev image, seeds, PAT — and is the same
script CI runs ([ADR-0020](../../docs/adr/00020-local-dev-parity.md)
Am. 4). It needs `docker`, `k3d`, `kubectl`, `helm`, `curl` on PATH
(mise provides the middle three) and is idempotent.

```sh
scripts/e2e-bootstrap.sh                       # from the repo root
set -a; source apps/e2e/.e2e-env; set +a       # E2E_TESTINBOX_TOKEN
cd apps/e2e && npx playwright test
```

Against any other deployed environment:

```sh
BASE_URL=https://staging.fluxvale.com E2E_TESTINBOX_TOKEN=<pat> npx playwright test
```

## Environment

| Variable | Purpose |
|---|---|
| `BASE_URL` | Target stack (default: `https://app.fluxvale.lvh.me`) |
| `E2E_TESTINBOX_TOKEN` | Admin PAT for the TestInbox JSON API ([ADR-0024](../../docs/adr/00024-e2e-review-environments.md) Am. 1); the sign-in and lifecycle tests skip without it |
| `E2E_RUNTIME` | Narrows what runs; the BASE_URL host sets the ceiling — any non-local, non-staging host is production-class (read-only) no matter what this says. Gates: lifecycle runs on local + staging (#116); sign-in never runs against production |
| `E2E_RUN_ID` | Run-scoped uniqueness (email + instance names); defaults to a timestamp |
| `E2E_IDLE_SLEEP_AFTER_SECONDS` | Bootstrap seam (#210 part 3): overrides the stack's idle threshold (default 180s; the timers CI leg sets 45s, the nightly 3600s) |
| `E2E_SWEEP_CRONEXPR` | Bootstrap seam (#210 part 3): overrides the stack's idle-sweep cron (default every-minute for E2E; the nightly restores `*/5`) |
| `E2E_SLEEP_WAIT_MS` | scale-to-zero spec: budget for reaching `Sleeping` (default 9 min; nightly 70 min) |
| `E2E_TEST_TIMEOUT_MS` | scale-to-zero spec: per-test timeout (default 30 min; nightly 75 min) |
| `E2E_PROBE_WINDOW_MS` | scale-to-zero spec: how long the probe test outlives one sweep cadence (default 6 min; timers CI leg 150s) |

## Tests

- `health.spec.ts`, `public-pages.spec.ts` — read-only, run anywhere
  (the production subset).
- `landing.spec.ts` — the marketing landing renders (hero, CTAs).
- `root-session.spec.ts` — `/` is session-aware (#207): marketing
  landing signed out, dashboard + user menu signed in.
- `switcher-dismiss.spec.ts` — #284: the org switcher closes on
  outside click and Esc (native `<details>` only closes on a summary
  re-click). #551: the account user menu rides the same hook and the
  same two pins. Signed-in chrome, so the same gates as sign-in.
- `sign-in.spec.ts` — the human login flow via TestInbox; staging and
  local. #219 pins the native fallbacks too: the same round-trip with
  the WebSocket handshake blocked (the forms POST natively while the
  socket is down) and with JavaScript disabled.
- `actual-lifecycle.spec.ts` — ActualBudget's lifecycle (#492): deploy
  through the stepper → running → HTTPS UI + `/health` → the
  first-open claim over the wire (needs-bootstrap false → bootstrap →
  login; ADR-0034 Am. 1) → stop → start → destroy. The stop/start
  round-trip is the restart-cleanliness proof. 22-minute budget
  (12 min running wait + 1 min stop + 8 min start, plus overhead);
  the ~120 MB image pull rides the first deploy. Local + staging
  (#116); production stays read-only.
- `file-access.spec.ts` — #190: deploy Kavita → rclone put through
  /dav → the file lands in the instance volume. Local + staging;
  needs rclone on PATH.
- `kavita-ingest.spec.ts` — #679: deploy Kavita → rclone-put a real
  EPUB into a series subfolder through /dav → Kavita's own API
  registers an admin and creates a library over the mount, and its
  scan must surface the series. The subfolder IS the regression:
  Kavita's scanner silently skips loose files at a library root.
  Local + staging; needs rclone on PATH.
- `forgejo-lifecycle.spec.ts` — Forgejo's full lifecycle through the
  real UI: sign-in via TestInbox → catalog → deploy → running →
  instance URL (with the #181 first-open check: `/user/sign_up`
  answers — registration open, first registrant becomes admin) →
  stop → destroy. Crosses the real cluster: `running`
  waits out the image pull plus the reconcile cron's minute
  granularity — the test carries a 15-minute budget; a red runner is
  usually a broken flow, not a slow one. Local + staging (#116);
  production stays read-only.
- `scale-to-zero.spec.ts` — #203 ([ADR-0036](../../docs/adr/00036-scale-to-zero-wake-on-use.md)): deploy → idle → sleeps
  (storage-only billing) → request → wakes → serves, and probe
  traffic must not wake a sleeper. Serial, local-only: the timers CI
  leg's compressed knobs (#210 part 3 — 45s threshold + every-minute
  sweep) make each idle cycle ~105s; a local bootstrap run keeps the
  180s threshold (beacon-staleness guard) for ~4-minute cycles; the
  nightly full-cadence workflow runs the real 1h + */5 pair.
- `umami-lifecycle.spec.ts` — Umami's lifecycle (#576; the bundled
  row since #612 S4 — the OQ #3 takeover's proof consumer): deploy
  through the stepper filling the ONE required input (APP_SECRET —
  DATABASE_URL never renders: the bundled PostgreSQL 18 inside the
  instance's pod owns it and the platform composes it at deploy) →
  running → HTTPS UI + `/api/heartbeat` → the default admin signs in
  over the API
  ([ADR-0034](../../docs/adr/00034-first-run-contract.md) Am. 2) → a
  run-unique website is created through the API (the persistence
  witness — the default admin cannot witness survival: the first
  migration re-seeds it on an empty database) → pod delete → the
  witness website still answers (the bundled DB's data rode the PVC) →
  stop ($0.40/mo stopped — 10 GB storage now holds the data) → start →
  the witness website still answers → destroy. Local only, like
  backups.spec.ts (the restart leg kubectl-deletes the app pod);
  production stays read-only.
- `docmost-lifecycle.spec.ts` — Docmost's lifecycle (#609): deploy
  through the stepper filling the three required inputs (DATABASE_URL,
  REDIS_URL, and APP_SECRET — the BYO-interim shape: the database is
  played by the stack's own CNPG the umami-lifecycle way, and Redis by
  a per-run pod + service in a per-run namespace the spec creates,
  since no bundled consumer exists yet) → running → HTTPS UI (the SPA
  login form renders and signs the admin in, the umami render-proof
  shape) + `/api/health` with database and redis both up → the setup
  page's first account becomes the workspace admin and the page closes
  ([ADR-0034](../../docs/adr/00034-first-run-contract.md)) → a file
  uploads through the app's own multipart endpoint and reads back (the
  volume proof: UID 1000 writes the PVC through the pod's fsGroup
  grant) → stop ($0.24 stopped — the 5 GB upload volume) → start →
  the admin still signs in and the uploaded file still reads (the
  external database held the rows, the volume held the bytes) →
  destroy, and the per-run database, role, and Redis namespace all go
  away. Local only, like backups.spec.ts (same reason); production
  stays read-only.

CI: the `e2e` job (`.github/workflows/ci.yml`) bootstraps the same
script on an ephemeral k3d — sharded by file (#210): a `lifecycle`
leg (instance-deploying specs), a `timers` leg (platform-timer-bound
specs — scale-to-zero on the bootstrap's compressed cadence), and a
`pages` leg (the rest), one report artifact per leg. A new spec file
joins a leg's list in the workflow matrix — it won't run in PR CI
otherwise, and `scripts/lint-e2e-legs.sh` (an early step of the e2e
job) reds on a spec no leg lists. A spec waiting on a fix before
joining its leg is declared inline in that script's gap list (empty
when nothing is parked), so an unlegged spec is always either gated
or explained. The per-merge post-deploy smoke retired with #556 (the
readiness gate that replaced it runs no behavioral suite); the
nightly workflow (`.github/workflows/e2e-nightly.yml`) runs the full suite at the real
1h + */5 cadence on main, daily.

## Captures

PR screenshots and GIF source material go through the ONE canonical
tool, `capture.mjs` (#510). One-off capture scratch NEVER merges —
route lists and bespoke scripts live outside the repo (e.g.
/tmp/opencode, swept at lane close); loop the tool in shell instead.
It replaces the retired per-surface kernels (`screenshot.mjs`,
`access_wake_screenshot.mjs`) with their behaviors: the real
`/auth/session` sign-in for authenticated pages (mint a token the
`*_seed.exs` way — no test backdoors), the `phx:theme` flip plus
`prefers-color-scheme`, networkidle + settle, full-page stills at
1440x900. `node capture.mjs --help` for every flag.

```sh
cd apps/e2e && npm ci && npx playwright install chromium   # once per machine
node capture.mjs https://app.fluxvale.lvh.me/about     # public page, light+dark
FV_TOKEN=<jwt> node capture.mjs https://app.fluxvale.lvh.me/ --name dashboard
node capture.mjs https://app.fluxvale.lvh.me/ --click 'text=Sign in' --name sign-in   # click-through state
FV_TOKEN=<jwt> node capture.mjs https://app.fluxvale.lvh.me/billing/topup --mask 'input[type=email]'  # never capture a secret
```

A token in the environment (`FV_TOKEN`) signs every run in — unset it for public captures; each run logs its auth state. Authenticated and anonymous surfaces are separate invocations — never present a signed-in capture as the visitor's page (#312's rule). Self-signed TLS is accepted for local origins only (localhost, `*.lvh.me`) — deployed environments must present a valid cert. The older per-surface scripts still in this directory are stranded instruments riding their surfaces' deletions — don't extend them, new captures go through the tool. GIFs: stills from the tool, motion via Playwright `recordVideo` → ffmpeg (the screenshot convention in
[`apps/platform/AGENTS.md`](../platform/AGENTS.md) has the mechanics).
