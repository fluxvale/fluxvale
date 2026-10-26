# ADR-0038: Instance exposure modes — public | private

**Status**: Accepted
**Date**: 2026-10-26
**Issue**: fluxvale/fluxvale#265

## Context

The instance-network-isolation exploration (#265) asked for the
network-isolation primitive: an instance that is **private** —
unreachable from the public internet — both as the foundation for a
private access layer and as an instant kill-switch when a runtime CVE
lands on an unpatched app ([ADR-0005](00005-customer-instances-as-namespaces.md)
Am. 4's parent decision: the k8s API surface is the product, and
NetworkPolicies are product features).

Owner decisions settled on #265 (spec fixed; all six scope items are
Terence's, not this ADR's):

- Exposure is `public | private`, default `public` — **no behavior
  change** for existing or new instances.
- **Private means**: no Traefik route for that instance's hostname on
  the public entrypoint + a NetworkPolicy denying ingress to the
  instance namespace from the edge. In-cluster paths (panel
  operations, sweeps, backups, health) must keep working.
- The panel toggle lives in the Availability card, pairing with
  Always On; the copy is honest — today private = manageable via the
  panel but **not** reachable, and the access layer is "upcoming",
  never promised with a date.
- **Wake/sleep coherence**: a private instance has no public traffic
  path, so nothing external wakes it; always-on still works; sleeping
  private instances stay asleep.
- **Provider-agnostic seam** (a decided constraint): the exposure
  state and any access plumbing must not assume Tailscale or any
  specific access provider — a future access layer attaches to the
  private state without schema change.
- **No billing change**: exposure itself is free; the future access
  layer is the separately-billed offering.

## Decision

### 1. `exposure` on the Instance row

An `InstanceExposure` enum attribute (`:text`-stored, like
`InstanceStatus`), member-toggled through `set_exposure` — the
`set_always_on` pattern: membership policy, no state-machine write.
The cluster application is **synchronous inside the action**: private
deletes the public IngressRoutes (app + `/dav`) first, then re-applies
the namespace NetworkPolicy with an empty
`ingress_from_namespaces` (same-namespace only — the policy must keep
existing; deleting it would re-admit everything); public re-mints the
routes in the row's current mode (wake mode for a sleeping instance —
a visitor must be able to wake it) and re-admits the edge. A cluster
failure fails the action and the write: the row never claims a
posture the cluster hasn't reached (the kill-switch must be honest).
Never-deployed and `:lost` rows are attribute-only — the next deploy
applies the row's posture.

### 2. EdgeRoutes owns the private posture

`EdgeRoutes` — already the one seam for how traffic reaches an
instance (#203) — gains `apply_private/2` (delete any public routes,
mint nothing, no wake targets) and dispatches to it from both
`apply_serving/2` and `apply_wake/2` when `exposure == :private`.
Callers (deploy, sleep, the wake restore) stay exposure-blind, and
`RestoreServingEdge` no-ops for private rows — the self-healing flip
must never mint a route the row says must not exist (the wake endpoint
is public; a crafted marker naming a private instance gets the
no-op).

### 3. In-cluster paths ride nothing the policy narrows

Panel operations (stop/start/wake), the reconciler's health read,
backups (in-namespace Jobs), and the sweeps all ride the API server
and same-namespace ingress — never the edge namespace exception the
private policy removes. Readiness probes (kubelet → pod) already ran
under the default-deny-plus-edge policy; removing the edge entry
changes nothing for them. Each path is pinned by test against a
private row.

### 4. Wake coherence is an absence, not machinery

A sleeping private instance stays asleep because nothing at the edge
can reach its wake route — there is none. Always-on remains the
stay-awake opt-out (the idle sweep skips it), and the owner's panel
Wake (in-cluster `start`) still works. The idle sweep otherwise
treats private rows like any other: default economics (storage-only
asleep) apply unchanged.

### 5. The seam is the schema, not a provider

`exposure` names **reachability**, not a mechanism. The future access
layer (any WireGuard-shaped thing, Tailscale included) grants
reachability to `:private` rows alongside `SetExposure` — it must not
widen the policy's edge entry, and it needs no new column.

## Rejected alternatives

- **Provider-coupled fields** (`tailscale_enabled`, ACL columns) —
  rejected by the issue's decided constraint; the schema would
  hard-code one vendor and the access layer would force a migration.
- **Deploy-time-only exposure** (the row read at deploy, toggles take
  effect on next deploy) — rejected: the kill-switch must be instant
  against a running instance, not eventual.
- **Deleting the NetworkPolicy to "close" a private namespace** —
  rejected: no policy means all ingress admitted; the empty
  external-source list is the denial (same-namespace floor kept).
- **HTTP-level auth on the public route instead of no route** —
  rejected: private means unreachable, not gated; a route that
  answers anything (a login, a 401) leaks existence and keeps the
  edge path warm.
