# FluxVale e2e

Playwright suite (ADR-0024). Four runtimes share it — local, review
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
| `E2E_TESTINBOX_TOKEN` | Admin PAT for the TestInbox JSON API (ADR-0024 Am. 1); the sign-in and lifecycle tests skip without it |
| `E2E_RUNTIME` | Narrows what runs; the BASE_URL host sets the ceiling — any non-local, non-staging host is production-class (read-only) no matter what this says. Gates: lifecycle runs on local + staging (#116); sign-in never runs against production |
| `E2E_RUN_ID` | Run-scoped uniqueness (email + instance names); defaults to a timestamp |

## Tests

- `health.spec.ts`, `public-pages.spec.ts` — read-only, run anywhere
  (the production subset).
- `landing.spec.ts` — the marketing landing renders (hero, CTAs).
- `root-session.spec.ts` — `/` is session-aware (#207): marketing
  landing signed out, dashboard + user menu signed in.
- `sign-in.spec.ts` — the human login flow via TestInbox; staging and
  local.
- `file-access.spec.ts` — #190: deploy Kavita → rclone put through
  /dav → the file lands in the instance volume. Local + staging;
  needs rclone on PATH.
- `forgejo-lifecycle.spec.ts` — Forgejo's full lifecycle through the
  real UI: sign-in via TestInbox → catalog → deploy → running →
  instance URL (with the #181 first-open check: `/user/sign_up`
  answers — registration open, first registrant becomes admin) →
  stop → destroy. Crosses the real cluster: `running`
  waits out the image pull plus the reconcile cron's minute
  granularity — the test carries a 15-minute budget; a red runner is
  usually a broken flow, not a slow one. Local + staging (#116);
  production stays read-only.
- `scale-to-zero.spec.ts` — #203 (ADR-0036): deploy → idle → sleeps
  (storage-only billing) → request → wakes → serves, and probe
  traffic must not wake a sleeper. Serial, local-only: the
  bootstrap's shortened idle threshold makes it waitable; the sweep
  cadence stays real (~8 min worst per idle cycle).

CI: the `e2e` job (`.github/workflows/ci.yml`) bootstraps the same
script on an ephemeral k3d — sharded by file (#210): a `lifecycle`
leg (instance-deploying specs), a `timers` leg (platform-timer-bound
specs — scale-to-zero today, at real cadence until #210 part 3
compresses it), and a `pages` leg (the rest), one report artifact per
leg. A new spec file joins a leg's list in the workflow matrix — it
won't run in PR CI otherwise. The deploy-gated smoke job runs the
suite post-deploy unsharded — staging full, production the read-only
subset (ADR-0024).
