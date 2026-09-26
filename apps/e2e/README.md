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
| `E2E_TESTINBOX_TOKEN` | Admin PAT for the TestInbox JSON API (ADR-0024 Am. 1); the lifecycle test skips without it |
| `E2E_RUN_ID` | Run-scoped uniqueness (email + instance names); defaults to a timestamp |

## Tests

- `health.spec.ts` — smoke, runs anywhere.
- `m3-exit-demo.spec.ts` — the M3 exit demo (ADR-0031): sign-in via
  TestInbox → catalog → deploy Forgejo → running → instance URL →
  stop → destroy. Crosses the real cluster: `running` waits out the
  image pull plus the reconcile cron's minute granularity — the test
  carries a 15-minute budget; a red runner is usually a broken demo,
  not a slow one.

CI: the `e2e` job (`.github/workflows/ci.yml`) bootstraps the same
script on an ephemeral k3d and runs the full suite; the HTML report
(and its failure screenshots/traces) uploads as a build artifact.
