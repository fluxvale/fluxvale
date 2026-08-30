# ADR-00020: Local development — production parity via k3d + Tilt + CNPG + a local overlay

**Status**: Proposed (until validated on-machine; accept when the inner loop
feels right)
**Date**: 2026-08-27

**Context**: local dev must run the app **inside a local Kubernetes cluster**
so runtime assumptions are consistent across every environment — in-cluster
service-account config for the k8s client, CNPG connection shape through the
k8s service, Traefik routing, the namespace convention, init-container
migrations. v1 ran the platform natively (`mix phx.server`) with kind hosting
only customer pods — a different runtime shape in dev than prod.

**Decision**:

- **k3d** (k3s-in-Docker) for the local cluster — same containerd, same
  bundled Traefik, same local-path storage as prod k3s. A checked-in k3d
  config replaces v1's OpenTofu-managed kind module (one command up/down,
  80/443 port-mapped).
- **Tilt** as the dev orchestrator — builds the dev image, applies manifests,
  and `live_update` syncs source into the running container; with Phoenix's
  code reloader the inner loop is seconds. Unified logs, port-forwards,
  per-resource status. (Alternatives: Skaffold, DevSpace — all Go; Tilt's
  ergonomics win. Extended via config, not code.)
- **CNPG Cluster in the local cluster** — same operator, same Cluster CR
  (smaller); identical connection-string shape. WAL-G skipped locally.
- **Parity via overlays, not separate manifests**: the fleet repo's base
  manifests (Deployment, probes, init migrations, ServiceAccount, RBAC,
  IngressRoute) get a `local/` overlay alongside `staging/`/`production/`,
  differing only in image tag, resources, and hostname. The app's k8s client
  uses in-cluster config everywhere.
- **Local DNS/TLS**: wildcard `*.fluxvale.lvh.me` → 127.0.0.1; Traefik's
  default self-signed cert stands in for Let's Encrypt.
- **`mix test` and CI stay native** against a plain Docker Postgres — the
  cluster is for k8s-touching integration work (Instance lifecycle,
  reconcile, deploy orchestration), not unit tests.

**Parity ledger** — matches prod: k8s object shape, CNPG operator + service
DNS, in-cluster client config, Traefik routing, namespace convention, seeds,
env-var shape, migration path. Deliberately differs: dev image runs
`mix phx.server` (prod runs the OTP release — that delta is what staging
verifies), self-signed TLS, no Cloudflare edge, Tilt applies directly
(no image automation), no backups.

**Tooling discipline**: no custom Go tooling until a felt pain survives the
off-the-shelf stack (the v1 meta-work lesson). The only sanctioned custom
wrapper is a thin `fluxvale dev` subcommand in the CLI ([ADR-00019](00019-machine-first-api-cli-mcp.md)) — glue
over k3d/Tilt, written only after the pain is real.

**Acceptance criteria**: full stack up with one command; edit → synced
reload in single-digit seconds; `fluxvale-app-*` instances deployable
end-to-end locally through the same manifests prod uses.
