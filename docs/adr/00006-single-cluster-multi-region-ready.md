# ADR-00006: One cluster now, schema-ready for regions

**Status**: Accepted (amended — see Amendments 1–2)
**Date**: 2026-08-27

**Decision**:

- The DB schema treats multi-region as real from day one (`Cluster` table with
  a kubeconfig ref — cheap now, one table).
- **First rung — vertical**: FluxVale traction → buy a bigger Netcup box and
  migrate the platform stack there (new cluster + WAL-G restore + `Cluster`
  repoint + wildcard cert/DNS move); the current box is demoted to
  projects/experiments duty. v1's original "vertical scaling comes first"
  instinct, retained. The scheduled restore drill ([ADR-00009](00009-single-cnpg-cluster.md)) is the
  rehearsal runbook for this move.
- **Growth within a region**: more Netcup boxes in the same datacenter join as
  k3s nodes (agents for capacity; three server nodes for control-plane HA —
  odd etcd counts only). Node #2 triggers the storage decision: Longhorn
  (replicated PVCs) vs node-pinned local-path. Don't pre-install Longhorn on a
  single node.
- **New geography** = bootstrap a new cluster + add a `Cluster` row. Region
  routing = pick the cluster (v1's `ResolveClusterFromRegion` pattern).

**Rationale**: etcd quorum members need low latency (same metro/DC fine,
cross-continent not) — this cleanly splits "more capacity" (one cluster, more
nodes) from "geographic distribution" (cluster per region). A single cluster
spanning regions fights the design: WAN round-trips on every scheduling
decision, partitioned-quorum risk.

**Rejected**: single-cluster-spanning-regions; a worker in another region
under a Nuremberg control plane (works, but don't build a product on it).

## Amendment 1 (2026-09-01)

Node-join mechanics updated for Talos ([ADR-00022](00022-talos-linux.md)):
"boxes join as k3s nodes (agents)" becomes "boot worker ISO + apply config —
joins via the talosctl API"; control-plane HA means three control-plane
machine configs. The ladder's structure, same-DC constraint, vertical-first
rung, and storage decision are unchanged.

## Amendment 2 (2026-09-23): the local row carries no kubeconfig — Accepted

Nil `kubeconfig_ref` is the documented sentinel for **local** (#72): the
app authenticates in-cluster via its mounted service account
([ADR-0020](00020-local-dev-parity.md)), and a stored kubeconfig for the
cluster the pod runs in would duplicate credentials that rotate ~hourly.
A populated ref names a remote cluster; the ref format is decided when
the second cluster actually arrives ([ADR-0016](00016-deferred-triggers.md)
managed-k8s trigger). The k8s client does not route through the row until
then — `Cluster`'s one-cluster job is being Instance's FK target.
