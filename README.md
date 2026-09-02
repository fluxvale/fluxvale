# FluxVale

Managed hosting for open source applications.

Status: **v2, in active buildout** — the platform app is a walking skeleton
(M1) and the [build ladder](docs/adr/0031-build-order.md) climbs from here.
Source is [FSL-1.1](LICENSE.md): fair use now, Apache-2.0 after two years.

**Start with [`docs/`](docs/README.md)** — product, architecture, and the
[ADRs](docs/adr/) that record what's decided and why. Working agreements for
contributing (humans and agents) are in [`AGENTS.md`](AGENTS.md).

## Repo layout

```
apps/platform    # the Phoenix 1.8 + Ash app — one OTP release (:flux_vale)
apps/e2e         # Playwright suite (grows from M3)
deploy/local/    # local production-parity stack (k3d + Tilt, ADR-0020)
docs/            # decisions home — read before proposing changes
```

## Local development

Toolchain comes from [mise](https://mise.jdx.dev) — exact-pinned, with a
committed lockfile:

```sh
mise install
```

**Plain app dev** (any PostgreSQL 16+ reachable by the default config —
how you run Postgres is your business):

```sh
cd apps/platform
mix setup
mix test        # or: mix ci — the full gate (format, deps, warnings, credo, test)
mix phx.server  # http://localhost:4000
```

**Production-parity dev** (ADR-0020: the app runs inside a local k8s
cluster — CNPG, Traefik, real probes — because v1 taught us dev/prod drift
hurts):

```sh
k3d cluster create --config deploy/local/k3d.yaml   # once; includes a local registry
tilt up                                              # from the repo root; UI at localhost:10350
curl -sk https://app.fluxvale.lvh.me/health          # through Traefik (self-signed)
```

Edit code; the reload lands in milliseconds (Tilt syncs source, Phoenix's
code reloader recompiles). Use `tilt up`, not `tilt ci`.

**E2E** (smoke suite today; grows from M3):

```sh
cd apps/e2e
npx playwright install chromium   # once
npx playwright test               # against localhost:4000 or BASE_URL=<any env>
```
