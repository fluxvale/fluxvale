# FluxVale smoke

Bruno collection (apps/smoke) — the API-level oracle for both deployed
envs (docs/deployment.md): liveness, readiness, the auth gate, and a
PAT-authed read. Read-only everywhere; destructive flows are the
Playwright suite's job (apps/e2e).

Same collection, two runtimes: the deploy-gated CI job 3 runs it after
watch-deploy; the scheduled cron (.github/workflows/smoke.yml) runs it
every 30 min, checks version currency (each env's /health version
current against main within a grace window — `scripts/version-currency.mjs`),
and remote-writes the smoke heartbeat on full success — series absence
pages via the fleet repo's dead-man rule.

## Run

Node comes from the repo's mise config.

```sh
npx bru run --env Staging    --env-var pat=$SMOKE_PAT_STAGING
npx bru run --env Production --env-var pat=$SMOKE_PAT_PRODUCTION
```

The PAT is injected per run (CI secret) — never stored in the repo.
Mint/rotate: release rpc per env — resolve the user, then mint with
the authorize-free operator path; `scopes: []` suffices (the smoke
read is `/api/v1/me`, scopeless). Value into the matching GitHub
Actions secret, revoke the old token (docs/deployment.md):

```elixir
{:ok, user} = FluxVale.Identity.User.get_by_email("admin@fluxvale.com", authorize?: false)
{:ok, %{token: token}} =
  FluxVale.Identity.mint_pat(nil, %{user_id: user.id, name: "smoke", scopes: []}, authorize?: false)
```

`scripts/heartbeat.mjs` — the scheduled run's remote-write; run by CI
with `PROM_REMOTE_WRITE_USERNAME`/`PROM_REMOTE_WRITE_TOKEN` set.

`scripts/version-currency.mjs` — the scheduled run's deploy-lag oracle
(#242): both envs' `/health` versions against the newest
platform-carrying sha on `main`, grace via `CURRENCY_GRACE_HOURS` (the
workflow's `grace_hours` dispatch input).
