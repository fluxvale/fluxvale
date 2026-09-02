# ADR-00020: Local development — production parity via k3d + Tilt + CNPG + a local overlay

**Status**: Accepted (Amendment 1 — validated on-machine 2026-09-02; see below)
**Date**: 2026-08-27

**Context**: local dev must run the app **inside a local Kubernetes cluster**
so runtime assumptions are consistent across every environment — in-cluster
service-account config for the k8s client, CNPG connection shape through the
k8s service, Traefik routing, the namespace convention, init-container
migrations. v1 ran the platform natively (`mix phx.server`) with kind hosting
only customer pods — a different runtime shape in dev than prod.

**Decision**:

- **k3d** (k3s-in-Docker) for the local cluster — fast, lightweight, and
  increasingly parity-*compatible* rather than parity-*exact* since prod
  moved to Talos ([ADR-00022](00022-talos-linux.md)): k3d runs k3s/upstream-adjacent
  k8s, while Traefik and local-path storage being **charts in both
  environments** (no k3s bundle anywhere) actually brings the stacks closer.
  True-parity option when needed: `talosctl cluster create` (QEMU VMs,
  heavier — the officially supported Talos dev loop). A checked-in k3d
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

## Amendment 1 (2026-09-02): validated on-machine — Accepted

The M1 implementation (#7) validated the decision end-to-end on real
hardware: k3d (Traefik bundled-chart disabled, 80/443 via loadbalancer),
CNPG operator 0.29.0 + Cluster CR, Traefik 41.4.0 chart with self-signed
TLS, dev image running `mix phx.server` with init-container migrations.
Measured: healthy app at `https://app.fluxvale.lvh.me` through the full
Traefik → Service → probe-gated chain; source edit → served response in
**61ms** (Phoenix code reloader recompile included — live_update's file
sync rides on this); CNPG force-kill → `/health/ready` flipped 503 while
`/health` stayed 200, traffic restored in ~6s. Acceptance criteria met
minus `fluxvale-app-*` instances (M3 scope, same manifests path).

Operational notes discovered during validation (recorded so they aren't
re-learned):

- **k3d needs its local registry** (`registries.create` in k3d.yaml) —
  Tilt pushes dev images there; nothing touches docker.io. Nodes address
  it as `fluxvale-registry:5000` (docker network name), the host as
  `127.0.0.1:5000`.
- **CRDs race static applies**: the CNPG `Cluster` CR and Traefik's
  `IngressRoute` must apply via runtime custom deploys ordered after
  their operator/chart — Tilt's static `k8s_yaml` pass otherwise drops
  or fails them.
- **`tilt ci` wedged on this machine** (charts deploy, then the scheduler
  never starts dependents); `tilt up` — the intended dev-loop vehicle —
  works. Batch validation is manual today.
- **The dev image must bind 0.0.0.0** (`PHX_SERVER` set in-container):
  k8s probes and Service routing hit the pod IP, while host dev keeps
  127.0.0.1.
- helm 4 quirks with Tilt: `--repo` wants unprefixed chart names, and
  custom-deploy stdout must be `-o yaml` (or discarded) for Tilt's parser.
