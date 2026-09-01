# ADR-00007: FluxCD retained; separate fleet repo

**Status**: Accepted
**Date**: 2026-08-27

Flux was **not** a v1 pain — the digest-commit noise was, and it is
quarantined by the repo split rather than by abandoning GitOps.

**Decision**: a separate **fleet repo** (`fluxvale/infrastructure`) holds Ansible
bootstrap playbooks + every cluster manifest (Traefik, cert-manager
**including its CRs/Issuers** — v1's ❌ sync-coverage rows, CNPG, RBAC, app
Deployments, ImagePolicies) + the `DEPLOYMENT.md` runbook. Flux watches only
this repo. The app repo and its CI hold **no cluster credentials** — CI builds
and pushes to GHCR, and version-polls the public health endpoints to verify
rollout.

**Rationale**:

1. Image-automation noise lands where tracking deployed state *is* the
   repo's job; the app repo's log stays clean.
2. Hard security boundary: agents/sessions working in the app repo cannot
   mutate infrastructure.
3. v1's sync-coverage table existed because some cluster state lived outside
   Flux; moving everything in fixes it structurally. DR = run playbook →
   `flux bootstrap` → converge → restore DB.

**Rejected — self-hosted PaaS panels (Docker-Compose orchestrators with a
UI), in any role**: that whole class has no real Kubernetes story
(clustering support is experimental at best). As a customer-app substrate it
forfeits every [ADR-00005](00005-customer-instances-as-namespaces.md) primitive, couples product core to a third-party
API whose stability is secondary, and costs ~1 GB+ COGS per region box. As a
platform deployer it recreates the Authentik-era mistake (a heavy
self-hosted OSS layer for something CI + systemd do natively) and fights for
ports 80/443 against the cluster's own Traefik. "Managed panel-as-a-service"
would also be a thinner moat than the managed-side differentiation FluxVale
is built on.
