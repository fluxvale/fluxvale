# FluxVale v2 — Project Documentation

This is the **FluxVale v2** repository: <https://github.com/fluxvale/fluxvale>
(kicked off 2026-08-27). It captures what was decided, **why**, what was
rejected, and what is still open.

v1 lives at <https://github.com/fluxvale/fluxvale_old> (read-only reference — see
[v1-salvage.md](v1-salvage.md) for the carry-over map).

## Document map

| Doc | Contents |
|---|---|
| [product.md](product.md) | What FluxVale is, positioning, pricing model |
| [architecture.md](architecture.md) | The settled stack, topology, environments, growth model, repo shape |
| [deployment.md](deployment.md) | Deploy pipeline, smoke tests, migration rules, rollback protocol |
| [observability.md](observability.md) | Monitoring stack, instrumentation plan, alert set |
| [adr/](adr/) | Architecture Decision Records — one file per decision, with rationale and rejected alternatives |
| [open-questions.md](open-questions.md) | Everything deliberately **not** decided yet |
| [v1-salvage.md](v1-salvage.md) | What to carry over from v1 (and what to leave behind) |

ADRs: [00001](adr/00001-restart-fresh-as-v2.md) restart · [00002](adr/00002-single-ash-liveview-app.md) LiveView app · [00003](adr/00003-ashauthentication-drop-authentik.md) auth · [00004](adr/00004-bare-metal-netcup-k3s.md) Netcup+k3s · [00005](adr/00005-customer-instances-as-namespaces.md) instances-as-namespaces · [00006](adr/00006-single-cluster-multi-region-ready.md) multi-region · [00007](adr/00007-fluxcd-fleet-repo.md) Flux/fleet repo · [00008](adr/00008-app-runs-in-cluster.md) app in-cluster · [00009](adr/00009-single-cnpg-cluster.md) one CNPG cluster · [00010](adr/00010-staging-namespace-flag-gated.md) staging/flags · [00011](adr/00011-simultaneous-deploy-post-deploy-smoke.md) deploy+smoke · [00012](adr/00012-observability-grafana-cloud.md) observability · [00013](adr/00013-additive-migrations.md) migrations · [00014](adr/00014-rollback-protocol.md) rollback · [00015](adr/00015-no-auto-remediation.md) no auto-remediation · [00016](adr/00016-deferred-triggers.md) deferred triggers · [00017](adr/00017-docs-home-adr-scope.md) docs home · [00018](adr/00018-repo-visibility.md) repo visibility · [00019](adr/00019-machine-first-api-cli-mcp.md) machine-first API · [00020](adr/00020-local-dev-parity.md) local dev parity · [00021](adr/00021-secrets-bws-operator.md) secrets (BWS operator) · [00022](adr/00022-talos-linux.md) Talos · [00023](adr/00023-day-one-gates.md) gates/flags · [00024](adr/00024-e2e-review-environments.md) E2E/review envs · [00025](adr/00025-seo-content-architecture.md) SEO/content · [00026](adr/00026-feedback-board.md) feedback board · [0027](adr/00027-admin-surface-ashadmin.md) AshAdmin · [0028](adr/00028-flat-rate-pricing.md) flat-rate pricing — full index in [adr/README.md](adr/README.md).

## Working with these docs (humans and agents)

- **Read [adr/](adr/) before proposing changes** to infrastructure,
  deployment, or architecture. Accepted ADRs are settled — do not re-litigate them
  in a work session. If new evidence justifies a change, propose an **amendment**
  (append an `## Amendment N` section to the ADR with date and rationale —
  conventions in [adr/README.md](adr/README.md)).
- **Anything not decided lives in [open-questions.md](open-questions.md).** If you
  find yourself inventing an answer to one of those, stop and surface it instead.
- These docs describe the *target* architecture during scaffolding. As reality
  lands, update the docs in the same PR as the change.
- Process weight is a v1 scar: keep workflow machinery proportional to shipped
  product. Meta-work must justify itself like any other code.
