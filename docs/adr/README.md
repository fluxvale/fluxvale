# ADRs — Architecture Decision Records

One decision per file: `NNNNN-title.md`. Each records the decision, its
rationale, and the **rejected alternatives** — the last one matters most,
because it's what stops a future session from re-proposing something we
already ruled out.

## Index

| # | Decision | Status |
|---|---|---|
| [ADR-00001](00001-restart-fresh-as-v2.md) | Restart fresh as v2; carry patterns, not process | Accepted |
| [ADR-00002](00002-single-ash-liveview-app.md) | Single Phoenix + Ash + LiveView app; no SPA | Accepted |
| [ADR-00003](00003-ashauthentication-drop-authentik.md) | AshAuthentication passwordless (email codes); drop Authentik | Accepted (amended — see Amendments 1–4) |
| [ADR-00004](00004-bare-metal-netcup-k3s.md) | Bare-metal Netcup (Talos per ADR-00022); reject managed Kubernetes | Accepted (amended — see Amendment 1) |
| [ADR-00005](00005-customer-instances-as-namespaces.md) | Customer workloads as k8s namespaces (the Instance model) | Accepted (amended — see Amendments 1–5) |
| [ADR-00006](00006-single-cluster-multi-region-ready.md) | One cluster now, schema-ready for regions; vertical first | Accepted (amended — see Amendments 1–2) |
| [ADR-00007](00007-fluxcd-fleet-repo.md) | FluxCD retained; separate fleet repo | Accepted |
| [ADR-00008](00008-app-runs-in-cluster.md) | Platform app runs in-cluster | Accepted |
| [ADR-00009](00009-single-cnpg-cluster.md) | One shared CNPG cluster; managed PostgreSQL is the scaling path | Accepted |
| [ADR-00010](00010-staging-namespace-flag-gated.md) | Staging = same-box namespace, feature-flag gated | Accepted |
| [ADR-00011](00011-simultaneous-deploy-post-deploy-smoke.md) | Simultaneous deploy + post-deploy smoke; gate-on-demand | Accepted (amended — see Amendment 1) |
| [ADR-00012](00012-observability-grafana-cloud.md) | Observability: Alloy → Grafana Cloud free tier | Accepted (amended — see Amendments 1–4) |
| [ADR-00013](00013-additive-migrations.md) | Migration discipline: additive-only per release | Accepted (amended — see Amendment 1) |
| [ADR-00014](00014-rollback-protocol.md) | Rollback protocol: revert PRs + counter-migrations | Accepted (amended — see Amendment 1) |
| [ADR-00015](00015-no-auto-remediation.md) | No auto-remediation: alert + prepared revert PR | Accepted |
| [ADR-00016](00016-deferred-triggers.md) | Named revisit triggers for deferred items | Accepted (amended — see Amendment 1) |
| [ADR-00017](00017-docs-home-adr-scope.md) | Docs home: one ADR log here, covering the product + org-wide infra | Accepted |
| [ADR-00018](00018-repo-visibility.md) | Repo visibility: app public under FSL, fleet repo private | Accepted (amended — see Amendment 1) |
| [ADR-00019](00019-machine-first-api-cli-mcp.md) | Machine-first API: JSON:API + CLI + MCP server from day one | Accepted (amended — see Amendments 1–5) |
| [ADR-0020](00020-local-dev-parity.md) | Local dev: production parity via k3d + Tilt + CNPG + local overlay | Accepted (amended — see Amendments 1–5) |
| [ADR-0021](00021-secrets-bws-operator.md) | Secrets: BWS Kubernetes operator primary (per-env machine accounts; EU vault) | Superseded (amended — see Amendment 3) |
| [ADR-0022](00022-talos-linux.md) | Talos Linux: the OS *is* the cluster; Ansible exits; Omni deferred | Accepted (amended — see Amendment 1) |
| [ADR-0023](00023-day-one-gates.md) | Day-one gates: AccessRule (staging/beta invites) + FeatureFlag design | Accepted (amended — see Amendments 1–6) |
| [ADR-0024](00024-e2e-review-environments.md) | E2E + review environments: per-PR Playwright, fleet-repo-provisioned | Accepted (amended — see Amendments 1–2) |
| [ADR-0025](00025-seo-content-architecture.md) | SEO: in-app blog at /blog, catalog as programmatic SEO, noindex non-prod | Accepted (amended — Am. 1–3) |
| [ADR-0026](00026-feedback-board.md) | Feedback board: in-app, public read, paying-customers-write | Accepted (amended — see Amendment 1) |
| [ADR-0027](00027-admin-surface-ashadmin.md) | Admin surface: AshAdmin (generated CRUD through Ash actions) | Accepted (amended — see Amendments 1–7) |
| [ADR-0028](00028-flat-rate-pricing.md) | Pricing: allocation-based flat monthly rates, not measured usage | Accepted (amended — see Amendments 1–3) |
| [ADR-0029](00029-payments-adapter-selfmor.md) | Payments: adapter architecture; direct processing via pluggable providers (PH entity) | Accepted (amended — see Amendments 1–6) |
| [ADR-0030](00030-ops-domain.md) | Domain grouping: the Ops domain (FeatureFlag, AccessRule; operator resources) | Accepted |
| [ADR-0031](0031-build-order.md) | Build order: the milestone ladder (M1 skeleton → M7 launch-prep) | Accepted (amended — see Amendment 1) |
| [ADR-0032](00032-uuid-v7-ids.md) | IDs: UUIDv7 for uuid primary keys (app-side generation; ordering approximate, never a contract) | Accepted |
| [ADR-0033](00033-auto-seed-on-deploy.md) | Bring-up data seeds on deploy; missing invariants fail loudly | Accepted |
| [ADR-0034](00034-first-run-contract.md) | First-run contract: catalog-declared first-open posture (guaranteed env + locked-out keys + guidance) | Accepted (amended — see Amendments 1, 2) |
| [ADR-0035](00035-per-instance-file-access.md) | Per-instance file access: rclone WebDAV sidecar + per-instance generated credential (presigned R2 phase 2) | Accepted (amended — Am. 1–4) |
| [ADR-0036](00036-scale-to-zero-wake-on-use.md) | Scale-to-zero with wake-on-use: idle instances sleep after 1h, wake on the next request; always-on bills the 24/7 running rate | Accepted (amended — see Amendments 1–2) |
| [ADR-0037](00037-instance-backups-s3.md) | Instance backups: restic to BYO S3-compatible storage (R2 first); crash-consistent PVC snapshots; Oban sweep + k8s Jobs; namespace-Secret credentials; same-instance restore | Accepted (amended — see Amendment 1) |
| [ADR-0038](00038-instance-exposure-modes.md) | Instance exposure modes: public (default) \| private (no public route, edge ingress denied; provider-agnostic seam for the upcoming access layer); exposure is free | Accepted (amended — see Amendment 1) |
| [ADR-0039](00039-private-access-layer-tailscale.md) | Private access layer: per-org userspace Tailscale gateway (B1), `AccessProvider` boundary, gateway-existence billing, gateway wake intercept, the stale-sleep self-heal | Accepted (amended — see Amendment 1) (price pending — owner's) |
| [ADR-0040](00040-strong-private-access-and-custom-domains.md) | Strong private access + custom domains: serve raw-TCP tunnel to a Traefik `access` entrypoint, split-DNS claiming per (tailnet, domain), per-gateway-view resolver, verify-by-issuance domain registry, DNS-01 wildcard certs — public/private becomes a resolution question; wake-knock survives | Accepted (amended — see Amendments 1-3) |
| [ADR-0041](00041-gettext-i18n-foundation.md) | Gettext i18n foundation: en-only now; one locale seam (`FluxValeWeb.Locale`, session-first) + `lang` attribute; extract `--check-up-to-date` in `mix ci`; phase 2 extracts authed surfaces post-redesign, email copy via an explicit-locale mailer API | Accepted |
| [ADR-0042](00042-user-created-organizations.md) | User-created organizations: create-with-owner under a 10-org cap, the `personal_owner_id` marker, per-org wallets with their own top-up (Option A), Stripe-model membership via invites; transfers deferred | Accepted |
| [ADR-0043](00043-instance-resize.md) | Instance resize: stopped-first apply, CPU/RAM both ways, storage up-only behind a live StorageClass capability probe, create-equivalent re-pricing (fresh 1-year clock), append-only allocation-era trail | Accepted (amended — see Amendment 1) |
| [ADR-0044](00044-public-docs-surface.md) | Content home: `docs/public` + `docs/blog` source of truth, synced gitignored priv copies, `FluxVale.Docs` mirroring the blog lane, `/docs` SSR pages, lint-enforced public/internal boundary | Accepted |
| [ADR-0045](00045-bundled-backing-services.md) | Bundled per-instance backing services: Postgres/Redis as native-sidecar containers in the instance pod, catalog-declared majors + platform-owned exact pins, resources carved from the purchased allocation, generated credentials, loud create-time takeover rejection | Accepted |
| [ADR-0046](0046-storage-beyond-threshold.md) | Storage beyond the self-service threshold: request → operator approval queue, online storage-only growth, configured marginal overage rate (pass-through + margin, 3¢/GB ratified 2026-11-10 with a $5 wallet floor) | Accepted (amended — Am. 1) |
| [ADR-0047](00047-platform-admin-authority.md) | Blanket platform-admin authority: the existing platform admin sees and does everything on the 31-resource business set through one condition-pair bypass, never on a PAT, enforced by a doctrine gate that fails CI on undecided resources | Accepted (amended — see Amendment 1) |
| [ADR-0048](00048-ash-paper-trail-audit.md) | Audit trail: AshPaperTrail over the business set — one config posture, attributed surviving versions, actor-label tombstone, retention forever (flagged deliberate) | Accepted |
| [ADR-0049](00049-posthog-app-observability-split.md) | Observability split: PostHog for the app surface (analytics + error tracking + trace dual-export; EU; cookieless; replay off) — Grafana keeps metrics, synthetics, logs (Phase-3 gate) | Proposed |
| [ADR-0050](00050-operational-console.md) | Operational console: curated at-a-glance health section, linked-not-embedded, no widget without a real source; server-side whitelisted proxies for third-party reads | Accepted |
| [ADR-0051](00051-tfprovider-repo-extraction.md) | The Terraform/OpenTofu provider leaves the monorepo: fluxvale/terraform-provider-fluxvale, history kept via filter-repo, plain vX.Y.Z tags, versioned registry assets (manifest, SHA256SUMS, binary .sig) on GPG-signed releases — registry-ready | Accepted (amended — see Amendment 1) |
| [ADR-0052](00052-instance-env-updates.md) | In-place instance env updates: one merge verb, row-is-truth / Secret-is-projection, explicit removes, platform-owned keys refused, restart-after-commit with an honest partial-failure answer | Accepted |
| [ADR-0053](00053-terraform-secret-env.md) | Secret env values: `fluxvale secrets encrypt` produces an `enc:v1:` marker the platform opens at deploy; one platform key, ciphertext bound to org + variable; Terraform carries the locked box, never the secret | Accepted (design; build deferred until T1–T3) |

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
