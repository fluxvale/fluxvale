# FluxVale smoke

Bruno collection (apps/smoke) — the API-level oracle for both deployed
envs (docs/deployment.md): liveness, readiness, the auth gate, and a
PAT-authed read. Read-only everywhere; destructive flows are the
Playwright suite's job (apps/e2e).

Same collection, two runtimes: the deploy-gated CI job 3 runs it after
watch-deploy; the scheduled cron (.github/workflows/smoke.yml) runs it
every 30 min and remote-writes the smoke heartbeat on full success —
series absence pages via the fleet repo's dead-man rule.

## Run

Node comes from the repo's mise config.

```sh
npx bru run --env Staging    --env-var pat=$SMOKE_PAT_STAGING
npx bru run --env Production --env-var pat=$SMOKE_PAT_PRODUCTION
```

The PAT is injected per run (CI secret) — never stored in the repo.
Mint/rotate: release rpc per env (`FluxVale.Identity.User.mint_pat/2`,
authorize-free operator path), value into the matching GitHub Actions
secret, revoke the old token (docs/deployment.md).

`scripts/heartbeat.mjs` — the scheduled run's remote-write; run by CI
with `PROM_REMOTE_WRITE_USERNAME`/`PROM_REMOTE_WRITE_TOKEN` set.
