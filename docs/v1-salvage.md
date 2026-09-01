# v1 Salvage Map

v1 lives at <https://github.com/fluxvale/fluxvale_old> (read-only). High-value carry-overs
are code that encodes hard-won correctness — worth porting nearly verbatim —
plus runbooks encoding operational knowledge.

## Salvage (high value)

Paths in the "v1 path" column are relative to the v1 repo root
(<https://github.com/fluxvale/fluxvale_old>).

| v1 path | What | v2 destination |
|---|---|---|
| `apps/platform/lib/flux_vale/domains/infrastructure/resources/pod.ex` + `pod/*.ex` | Instance state machine, AshOban triggers (deploy/reconcile/settle_usage/teardown), K8s orchestration, error paths, staleness timeouts. The most intricate, most-tested v1 code. Port note: v1 generates `app-<id>` namespaces — v2 uses `fluxvale-app-<id>` (namespace convention, architecture.md). | Ash `Infrastructure` domain (`Instance` resource) |
| `apps/platform/lib/flux_vale/domains/billing/` | Wallet + ledger (idempotency-keyed posting), advisory-locked usage settlement + metering anchors (`running_since`, `storage_metering_since`), double-charge prevention. | Ash `Billing` domain |
| `apps/platform/lib/flux_vale/clients/k8s/` | kubereq client + resource modules (Namespace, Deployment, Service, Ingress, PVC, Secret, Certificate, Node) | `clients/k8s` |
| `apps/platform/lib/flux_vale/domains/catalog/` + `priv/repo/seeds/catalog_data.yaml` + `seeds/catalog_data.ex` | Catalog model (Category/App/AppVersion), configurable env-var schema, idempotent YAML seeding | Ash `Catalog` domain |
| `apps/platform/priv/scripts/dump_openapi.exs` + per-resource `json_api` blocks | Offline OpenAPI spec generation (renders from compiled Ash resources — no running server) + API route design discipline | API tooling: feeds CLI/MCP client generation + staleness CI ([ADR-00019](adr/00019-machine-first-api-cli-mcp.md)) |
| `apps/platform/lib/flux_vale/domains/identity/` | PAT lifetime (1 yr), token store, janitor | `Identity` (swap AshAuthentication strategy: passwordless email code, not OIDC) |
| `apps/platform/lib/flux_vale/billing/dodo.ex` + `dodo/webhook.ex` | Standard Webhooks HMAC verification (constant-time, replay window), checkout client | `Billing` (if Dodo retained — OQ #4) |
| `bruno/` | API smoke collections | smoke suite (re-point, add staging/prod split) |
| `apps/web` Playwright suite | E2E smoke (per-PR screenshots pattern) | `apps/e2e` (monorepo; port + add per-PR/staging/prod split, ADR-00024) |
| `infra/flux/base/helm/*.yaml` | HelmRelease patterns: cert-manager, CNPG, Traefik (+ issuer CRs v1 kept outside Flux — v2 moves them in; Traefik/local-path become plain charts under Talos, [ADR-00022](adr/00022-talos-linux.md)) | fleet repo |
| `docs/infra/*.md` | Runbooks: server-provisioning, local-dns, postgresql-restore, rotate-bitwarden-token/vault-password, sftpgo-operator | fleet repo docs (prune SFTP parts) |
| v1 root `AGENTS.md` gotchas | Netcup SSH/fail2ban traps, provider-skew rule, Cloudflare proxy ≠ non-HTTP ports, HelmRelease conventions (bare chart name, `releaseName`, secrets via `valuesFrom`) | fleet repo `DEPLOYMENT.md` / runbooks |
| Rates + anchors config (`config.exs` usage_rates, per-env overrides) | Metering rates + anchor semantics (Netcup-COGS calibration) | app config |

## Leave behind

- **Ansible and its bootstrap roles** (`ssh`, `ufw`, `fail2ban`, `k3s`,
  `k3s_prereqs`) + the fnox role — Talos replaces the entire layer
  ([ADR-00022](adr/00022-talos-linux.md)): no SSH/sshd to harden, no k3s to
  install; their documented traps (forks, port-change handler hangs) die with
  them. Only the Netcup panel facts from the v1 gotchas survive, into the
  fleet repo's Talos runbook.

- **React SPA** (`apps/web` beyond E2E tests) — [ADR-00002](adr/00002-single-ash-liveview-app.md).
- **Authentik** (Helm release, Terraform branding, `infra/authentik/`) — [ADR-00003](adr/00003-ashauthentication-drop-authentik.md).
- **Reflector** — gone with the Authentik-era cross-namespace secret needs.
- **v1's CNPG configuration as-is** — CNPG stays, rebuilt with guardrails
  (per-tenant roles + connection limits, PgBouncer, WAL-G → R2) per
  [ADR-00009](adr/00009-single-cnpg-cluster.md).
- **Flux image-automation noise in the app repo** — moves to fleet repo
  ([ADR-00007](adr/00007-fluxcd-fleet-repo.md)), tag-based policies to keep the log legible.
- **The 23-skill corpus, worktree/quality-gate/epic machinery, beads archive**
  — v1's meta-work lesson. Reintroduce specific pieces only when product
  velocity demands them.
- **SFTPGo gateway + sidecar** (pending v2 decision, OQ #6).
- **Custom domains** (`Domain` resource, per-domain IngressRoute+Certificate)
  — deferred post-beta per the working sketch.
