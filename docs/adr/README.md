# ADRs — Architecture Decision Records

One decision per file: `NNNNN-title.md`. Each records the decision, its
rationale, and the **rejected alternatives** — the last one matters most,
because it's what stops a future session from re-proposing something we
already ruled out.

## Index

| # | Decision | Status |
|---|---|---|
| [00001](00001-restart-fresh-as-v2.md) | Restart fresh as v2; carry patterns, not process | Accepted |
| [00002](00002-single-ash-liveview-app.md) | Single Phoenix + Ash + LiveView app; no SPA | Accepted |
| [00003](00003-ashauthentication-drop-authentik.md) | AshAuthentication passwordless (email codes); drop Authentik | Accepted (amended — see Amendment 1) |
| [00004](00004-bare-metal-netcup-k3s.md) | Bare-metal Netcup (Talos per ADR-00022); reject managed Kubernetes | Accepted |
| [00005](00005-customer-instances-as-namespaces.md) | Customer workloads as k8s namespaces (the Instance model) | Accepted |
| [00006](00006-single-cluster-multi-region-ready.md) | One cluster now, schema-ready for regions; vertical first | Accepted |
| [00007](00007-fluxcd-fleet-repo.md) | FluxCD retained; separate fleet repo | Accepted |
| [00008](00008-app-runs-in-cluster.md) | Platform app runs in-cluster | Accepted |
| [00009](00009-single-cnpg-cluster.md) | One shared CNPG cluster; managed PostgreSQL is the scaling path | Accepted |
| [00010](00010-staging-namespace-flag-gated.md) | Staging = same-box namespace, feature-flag gated | Accepted |
| [00011](00011-simultaneous-deploy-post-deploy-smoke.md) | Simultaneous deploy + post-deploy smoke; gate-on-demand | Accepted |
| [00012](00012-observability-grafana-cloud.md) | Observability: Alloy → Grafana Cloud free tier | Accepted |
| [00013](00013-additive-migrations.md) | Migration discipline: additive-only per release | Accepted |
| [00014](00014-rollback-protocol.md) | Rollback protocol: revert PRs + counter-migrations | Accepted |
| [00015](00015-no-auto-remediation.md) | No auto-remediation: alert + prepared revert PR | Accepted |
| [00016](00016-deferred-triggers.md) | Named revisit triggers for deferred items | Accepted |
| [00017](00017-docs-home-adr-scope.md) | Docs home: one ADR log here, covering the product + org-wide infra | Accepted |
| [00018](00018-repo-visibility.md) | Repo visibility: app public under FSL, fleet repo private | Accepted |
| [00019](00019-machine-first-api-cli-mcp.md) | Machine-first API: JSON:API + CLI + MCP server from day one | Accepted |
| [0020](00020-local-dev-parity.md) | Local dev: production parity via k3d + Tilt + CNPG + local overlay | Proposed |
| [0021](00021-secrets-bws-operator.md) | Secrets: BWS Kubernetes operator primary + fnox bootstrap residual | Accepted — EU check pending |
| [0022](00022-talos-linux.md) | Talos Linux: the OS *is* the cluster; Ansible exits; Omni deferred | Accepted |
| [0023](00023-day-one-gates.md) | Day-one gates: AccessRule (staging/beta invites) + FeatureFlag design | Accepted |
| [0024](00024-e2e-review-environments.md) | E2E + review environments: per-PR Playwright, fleet-repo-provisioned | Accepted (amended — see Amendments 1–2) |
| [0025](00025-seo-content-architecture.md) | SEO: in-app blog at /blog, catalog as programmatic SEO, noindex non-prod | Accepted |
| [0026](00026-feedback-board.md) | Feedback board: in-app, public read, paying-customers-write | Accepted (amended — see Amendment 1) |
| [0027](00027-admin-surface-ashadmin.md) | Admin surface: AshAdmin (generated CRUD through Ash actions) | Accepted |
| [0028](00028-flat-rate-pricing.md) | Pricing: allocation-based flat monthly rates, not measured usage | Accepted |
| [0029](00029-payments-adapter-selfmor.md) | Payments: adapter architecture; self-MoR Xendit (MoR products refuse hosting; PH entity) | Accepted (amended — see Amendment 1) |

## Conventions

- **Status**: Accepted (settled — build on this) · Proposed (directionally
  agreed, awaiting first implementation) · Superseded (replaced by a later ADR,
  kept for the record).
- **Amendments**: accepted ADRs are settled — do not re-litigate them in a work
  session. If new evidence justifies a change, append an
  `## Amendment N (YYYY-MM-DD)` section to the ADR with the rationale, and
  update the index. Never edit history.
- New ADRs take the next number; superseding is by amendment or a new ADR that
  links back, never by deletion.
