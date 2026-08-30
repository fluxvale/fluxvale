# Architecture

Status: Accepted (see [adr/](adr/) — ADRs [00002](adr/00002-single-ash-liveview-app.md)–[00009](adr/00009-single-cnpg-cluster.md)).

## The settled stack

- **App**: single Phoenix 1.8 + Ash app — LiveView UI + **first-class JSON:API
  + hosted MCP endpoint** in one OTP release, one image ([ADR-00019](adr/00019-machine-first-api-cli-mcp.md)). No SPA; no
  OpenAPI→frontend types pipeline — the spec feeds the CLI/MCP clients instead.
- **Auth**: AshAuthentication — passwordless email one-time codes (no
  passwords) for web login; bearer tokens/PATs for machine access ([ADR-00003](adr/00003-ashauthentication-drop-authentik.md),
  [ADR-00019](adr/00019-machine-first-api-cli-mcp.md)). Authentik dropped.
- **Data**: PostgreSQL via CloudNativePG — **one shared CNPG cluster** on the
  box, separate database per tenant (platform prod, platform staging, each
  first-party product); per-tenant roles with connection limits + PgBouncer;
  WAL-G → R2 backups. Managed PostgreSQL is the migration path at traction
  ([ADR-00009](adr/00009-single-cnpg-cluster.md)); Postgres-level rehearsals and restore drills use temporary
  scratch clusters.
- **Workload substrate**: k3s on bare metal (Netcup Nuremberg). Customer
  instances = namespaces ([ADR-00005](adr/00005-customer-instances-as-namespaces.md)) with ResourceQuotas + NetworkPolicies.
  This is the product: the platform consumes namespaces, Deployment
  conditions, PVCs, quotas as product primitives via `kubereq`.
- **Edge**: Cloudflare (DNS, proxy, TLS, DDoS) → Traefik (bundled with k3s) →
  cert-manager with Let's Encrypt DNS-01.
- **Deploy**: FluxCD GitOps from a separate **fleet repo**; image automation
  deploys staging + prod simultaneously. CI never touches the cluster.
- **Secrets**: Bitwarden Secrets Manager via fnox (EU server). References only
  in git, never plaintext.
- **Observability**: Grafana Alloy agent → Grafana Cloud free tier (hosted
  LGTM). PromEx for Elixir metrics. See [observability.md](observability.md).

## Topology

```
Netcup box (Debian 13, "nuremberg-01")
├── systemd
│   └── k3s (control plane, etcd via --cluster-init)
└── k3s cluster (Flux-reconciled from the fleet repo)
    ├── flux-system
    ├── traefik, cert-manager
    ├── monitoring (Alloy agent)
    ├── CNPG shared cluster (prod DB + staging DB + product DBs)
    ├── fluxvale-staging    ← app release (tight ResourceQuota)
    ├── fluxvale-production ← app release
    └── fluxvale-app-<id>  ← customer instances (the cluster's reason to exist)
```

**Namespace convention**: every namespace carries an owner-scoped prefix —
FluxVale owns `fluxvale-*` (`fluxvale-staging`, `fluxvale-production`,
`fluxvale-app-<id>` customer instances, `fluxvale-app-stg-<id>` staging
instances); other first-party products use their own `<product>-*` prefixes.
Unambiguous ownership for kubectl, monitoring filters, cost attribution, and
NetworkPolicy conventions as the cluster accumulates products. The platform
creates a per-namespace RoleBinding for its service account when it creates
each instance namespace.

## Environments

| Env | Where | Purpose |
|---|---|---|
| local dev | k3d cluster + app in-cluster via Tilt + `local/` overlay ([ADR-00020](adr/00020-local-dev-parity.md)) — same runtime shape as prod; `mix test` stays native | development |
| staging | `fluxvale-staging` namespace, staging DB on the shared cluster | flag-gated exposure, stateful test sandbox (full Playwright), scratch-cluster drill companion |
| prod | `fluxvale-production` namespace, prod DB on the shared cluster | customers |

Staging and prod run **the same image at the same time**; feature flags gate
exposure ([ADR-00010](adr/00010-staging-namespace-flag-gated.md)/00011). Staging is not a promotion gate.

## Resource budget (16 GB box)

| Component | Approx RAM |
|---|---|
| k3s control plane + Traefik + cert-manager + Flux | ~1.5 GB |
| CNPG shared cluster | ~1–1.5 GB |
| Platform app (staging + prod releases) | ~1 GB |
| Alloy agent | ~0.1 GB |
| **Customer instances** | **~8–10 GB headroom** |

RAM is COGS. Every in-cluster component must justify its memory — that
discipline is what killed Authentik, Reflector, the React app, and self-hosted
LGTM ([ADR-00003](adr/00003-ashauthentication-drop-authentik.md), [ADR-00012](adr/00012-observability-grafana-cloud.md)).

## Growth model

| Event | Action | Notes |
|---|---|---|
| Need capacity / redundancy | Buy another Netcup box **in the same DC** → `k3s agent`, join cluster | flannel `wireguard` backend from day one (node traffic crosses public IPs); odd count of server nodes if control-plane HA |
| Node #2 arrives | Decide storage: Longhorn (replicated PVCs) vs node-pinned local-path | Don't pre-install Longhorn on a single node |
| New region (latency/residency) | Bootstrap a **new cluster**, add a `Cluster` row | etcd latency makes single-cluster-spanning-regions a non-starter |
| Revisit managed k8s / Flagger canary / self-hosted LGTM | Only when a concrete trigger fires | [ADR-00004](adr/00004-bare-metal-netcup-k3s.md), [ADR-00016](adr/00016-deferred-triggers.md) |

The DB schema treats multi-region as real from day one (`Cluster` table with
kubeconfig ref), but we run one cluster until revenue says otherwise.

## Repo shape

Two repos:

1. **App repo** (this one, **public under FSL-1.1**) — Phoenix/Ash
   application code, its CI (build image
   → GHCR → post-deploy smoke). CI holds **no cluster credentials**.
   **Also the docs home**: the ADR log here covers FluxVale-the-product *and*
   the org-wide infrastructure — the fleet repo, cluster, edge, CNPG clusters,
   deploy pipeline ([ADR-00017](adr/00017-docs-home-adr-scope.md)). Architecture and decisions are public;
   operational specifics are not ([ADR-00018](adr/00018-repo-visibility.md)).
2. **Fleet repo** (`fluxvale/infrastructure`, **private**) — Ansible bootstrap playbooks + every
   cluster manifest (Traefik, cert-manager **including its CRs/Issuers**, CNPG,
  RBAC, app Deployments, ImagePolicies) + operational runbooks
   (`DEPLOYMENT.md`, bootstrap, rotations). Its README links back to
   `fluxvale/fluxvale` → `docs/adr/` ("read before proposing changes").

Rule: **if it runs on the cluster, it lives in the fleet repo.** v1's
Flux-sync-coverage table (with its ❌ rows) existed because some cluster state
lived outside Flux; the fix is moving everything in, not maintaining a coverage
map. Disaster recovery = run Ansible playbook → `flux bootstrap` → wait for
convergence → restore DB from R2 → done.

Doc-type boundary ([ADR-00017](adr/00017-docs-home-adr-scope.md)): this repo holds the **why** (decisions,
product, architecture); the fleet repo holds the **how-to-operate** (runbooks).
Other SaaS products under the FluxVale org keep their own app-specific ADRs in
their own repos — platform and shared-infra decisions on their behalf are
made here. Cross-link, never mirror.
