# FluxVale e2e

Playwright suite (ADR-0024). Four runtimes share it — local, review
environments, staging, and prod (read-only subset) — selected entirely via
`BASE_URL`. The suite never starts a server; point it at one.

## Setup

```sh
npx playwright install chromium   # browser binaries (once per machine)
```

Node comes from the repo's mise config (`mise install` at the root).

## Run

```sh
# against a locally running platform (default BASE_URL):
npx playwright test

# against any deployed environment:
BASE_URL=https://staging.fluxvale.com npx playwright test
```

The suite grows from M3 (catalog → deploy → status flows, TestInbox
login). Until then this file is deliberately a smoke test only — no
harness before there's something to harness.
