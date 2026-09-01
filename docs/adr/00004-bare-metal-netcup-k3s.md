# ADR-00004: Bare-metal Netcup + k3s; reject managed Kubernetes

**Status**: Accepted (amended — see Amendment 1)
**Date**: 2026-08-27

**Decision**: Netcup RS 2000 G12 (8 dedicated EPYC cores, 16 GB ECC, 512 GB
NVMe, €21.61/mo actual billed) running k3s.

**Rationale**: post-2026 pricing makes bare metal stronger than at v1 start.
Equivalent managed-k8s capacity: ~€75–140/mo on EU cloud providers
(post-RAMpocalypse VM prices + €0.05–0.10/GB volumes — a storage-heavy
catalog product) or $150+/mo on hyperscalers ($74/mo control-plane fee
alone). Managed k8s sells what this architecture already has cheap: a
managed control plane (k3s is one binary), elasticity (irrelevant for
always-on hosting; per-second metering *charges* for always-on), node
auto-replacement (a ticket + playbook at beta scale). Storage economics
dominate: 512 GB NVMe included vs metered volumes.

**Netcup specifics**: cluster members must be same-DC (etcd latency — same
country isn't the bar); node traffic crosses public IPs, so flannel
`wireguard` is baked into the bootstrap playbook from day one.

**Reversibility**: the platform talks to clusters via kubeconfig through the
`Cluster` registry; a managed cluster slots in as a new region if a concrete
need ever appears. Other EU bare-metal hosters remain alternatives.

**Rejected**: managed Kubernetes in all forms — hyperscalers, EU cloud
providers, third-party managed control planes (€79–200/mo) — and
self-hosted PaaS panels as substrate (see [ADR-00007](00007-fluxcd-fleet-repo.md)).

## Amendment 1 (2026-09-01)

The substrate changed from k3s to **Talos Linux** ([ADR-00022](00022-talos-linux.md)):
the box runs Talos (immutable, API-managed node OS running upstream
Kubernetes) instead of Debian + k3s. Everything else in this ADR — the
bare-metal economics, Netcup specifics (same-DC etcd latency, wireguard over
public IPs — now a machine-config patch), managed-k8s rejection, reversibility
via the `Cluster` registry — is unchanged. "k3s is one binary" becomes "the
OS *is* the Kubernetes appliance."
