# ADR-00021: Secrets — Bitwarden SM Kubernetes operator (primary) + fnox (bootstrap residual)

**Status**: Accepted — with one named pre-adoption verification (EU region, below)
**Date**: 2026-08-28

**Context**: v1 materialized K8s Secrets at bootstrap time via the fnox CLI
(TOML mapping → Bitwarden Secrets Manager → Secrets), re-running Ansible on
rotation, with a known two-file-edit trap. Bitwarden now ships an official
Kubernetes operator (`bitwarden/sm-kubernetes`) that reconciles Secrets
declaratively and continuously. v2's charter is "do it right, then go fast":
adopt the declarative path as primary; keep fnox only where it is more
practical.

**Decision**:

- **Operator = primary**: every secret the cluster consumes at runtime syncs
  via `SecretStore` + `BitwardenSecret` CRs — **references only (BWS secret
  IDs), never values** — living in the fleet repo, Flux-managed like all
  cluster state, continuously reconciled from Bitwarden. Includes the app env
  secrets (Dodo keys, token-signing secret, SMTP — auth-critical under
  passwordless login), Cloudflare DNS token (cert-manager), WAL-G/R2 creds,
  Grafana Cloud creds (Alloy), and pull secrets (`dockerconfigjson` support)
  if the app image ever goes private.
- **fnox = bootstrap residual**: the operator's own machine-account token
  Secrets must exist before the operator runs — Ansible + fnox create them
  (the only values fnox touches; fnox.toml shrinks to ~2 entries). The
  Ansible Vault continues to hold only the BWS master token.
- **Least privilege by construction**: two BWS projects (`fluxvale-prod`,
  `fluxvale-staging`), one machine account each; per-namespace SecretStores
  reference the matching token — staging structurally cannot read prod
  secrets.
- **Local dev**: no Bitwarden in k3d — the `local/` overlay replaces CRs with
  plainly-fake Secrets; `local/` never feeds prod paths (ADR-00020).
- **CI secrets are a different store**: GitHub Actions secrets (smoke PAT)
  stay in GitHub, not Bitwarden.

**Cold start / DR sequence**: Ansible (ssh/ufw/fail2ban/k3s/flux) →
fnox materializes operator token Secrets → Flux installs operator →
SecretStores ready → BitwardenSecret CRs sync → consumers apply with
`dependsOn` ordering.

**Gotchas designed around**:

1. **Pre-adoption check — EU region**: the v1 vault is on `vault.bitwarden.eu`;
   the operator defaults to US and has community-documented EU friction.
   Verify the current operator version against EU before adoption. Fallback
   if broken: fnox remains primary (this ADR's division inverts) — never move
   the vault to US as a workaround.
2. Env vars don't hot-reload: rotation runbooks include a rollout restart of
   consuming Deployments (checksummed annotations later, if wanted).
3. Operator polls (no webhooks): rotation propagates in minutes — fine at
   monthly+ cadence.

**RAM**: ~100–200 MB for the operator — accepted as the price of declarative,
continuously-reconciled secrets (within the observability-adjacent budget
slack from ADR-00009's single-cluster consolidation).
