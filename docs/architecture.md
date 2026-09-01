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
- **Workload substrate**: **Talos Linux** on bare metal (Netcup Nuremberg) —
  immutable, API-managed node OS running upstream Kubernetes; no SSH/shell
  ([ADR-00022](adr/00022-talos-linux.md)). Customer
  instances = namespaces ([ADR-00005](adr/00005-customer-instances-as-namespaces.md)) with ResourceQuotas + NetworkPolicies.
  This is the product: the platform consumes namespaces, Deployment
  conditions, PVCs, quotas as product primitives via `kubereq`.
- **Edge**: Cloudflare (DNS, proxy, TLS, DDoS) → Traefik (HelmRelease) →
  cert-manager with Let's Encrypt DNS-01.
- **Deploy**: FluxCD GitOps from a separate **fleet repo**; image automation
  deploys staging + prod simultaneously. CI never touches the cluster.
- **Secrets**: Bitwarden Secrets Manager (EU vault) → official Kubernetes
  operator as primary (SecretStore + BitwardenSecret CRs — references only,
  Flux-managed, continuously reconciled); fnox shrinks to bootstrapping the
  operator's own machine-account tokens (ADR-00021).
- **Observability**: Grafana Alloy agent → Grafana Cloud free tier (hosted
  LGTM). PromEx for Elixir metrics. See [observability.md](observability.md).

## Topology

```
Netcup box (Debian 13, "nuremberg-01")
├── systemd
└── Talos Linux (immutable node OS: upstream k8s + etcd + flannel/wireguard)
    — no shell, no SSH; managed via the talosctl API
    (Flux-reconciled workloads from the fleet repo)
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
| Talos control plane + Traefik + cert-manager + Flux | ~1.5 GB |
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
| Need capacity / redundancy | Buy another Netcup box **in the same DC** → boot worker ISO + apply config → joins via API | wireguard flannel (machine-config patch) from day one; odd count of control-plane nodes if HA |
| Node #2 arrives | Decide storage: Longhorn (replicated PVCs) vs node-pinned local-path | Don't pre-install Longhorn on a single node |
| New region (latency/residency) | Bootstrap a **new cluster**, add a `Cluster` row | etcd latency makes single-cluster-spanning-regions a non-starter |
| Revisit managed k8s / Flagger canary / self-hosted LGTM | Only when a concrete trigger fires | [ADR-00004](adr/00004-bare-metal-netcup-k3s.md), [ADR-00016](adr/00016-deferred-triggers.md) |

The DB schema treats multi-region as real from day one (`Cluster` table with
kubeconfig ref), but we run one cluster until revenue says otherwise.

## Repo shape

**Monorepo** (v1-style, minus the SPA) — infra stays in the private fleet
repo:

```
fluxvale/fluxvale (this repo, public, FSL-1.1)
├── apps/
│   ├── platform/    # the Phoenix/Ash app — one OTP release (ADR-00002)
│   ├── e2e/         # Playwright suite (ADR-00024)
│   └── cli/         # future: the Go CLI (ADR-00019)
├── docs/            # this documentation
└── (no root-level deps — v1's rule survives)

fluxvale/infrastructure (private fleet repo — Talos configs + all manifests,
ADR-00007/00022)
```

Per-app CI with path filters (v1 pattern). Review environments for PRs are
provisioned **on the single cluster by the platform itself** via a scoped
service PAT — app-repo CI never gains cluster credentials
([ADR-00024](adr/00024-e2e-review-environments.md)).

The fleet repo (`fluxvale/infrastructure`, **private**) holds the Talos
machine-config patches + every cluster manifest (Traefik, cert-manager
**including its CRs/Issuers**, CNPG, RBAC, app Deployments, ImagePolicies) +
operational runbooks (`DEPLOYMENT.md`, bootstrap, rotations). Its README
links back to `fluxvale/fluxvale` → `docs/adr/` ("read before proposing
changes"). This repo (public, FSL-1.1) is the docs home — decisions,
product, architecture ([ADR-00017](adr/00017-docs-home-adr-scope.md),
[ADR-00018](adr/00018-repo-visibility.md)).

Rule: **if it runs on the cluster, it lives in the fleet repo.** v1's
Flux-sync-coverage table (with its ❌ rows) existed because some cluster state
lived outside Flux; the fix is moving everything in, not maintaining a coverage
map. Disaster recovery = boot Talos ISO → apply config → `flux bootstrap` → wait for
convergence → restore DB from R2 → done.

Doc-type boundary ([ADR-00017](adr/00017-docs-home-adr-scope.md)): this repo holds the **why** (decisions,
product, architecture); the fleet repo holds the **how-to-operate** (runbooks).
Other SaaS products under the FluxVale org keep their own app-specific ADRs in
their own repos — platform and shared-infra decisions on their behalf are
made here. Cross-link, never mirror.
