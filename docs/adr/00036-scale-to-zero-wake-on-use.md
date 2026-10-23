# ADR-0036: Scale-to-zero with wake-on-use

**Status**: Accepted
**Date**: 2026-10-22
**Issue**: fluxvale/fluxvale#203

## Context

FluxVale's economic model bets on oversubscription: instances idle most
of the time. A running-but-unvisited instance bills its owner the full
rate while costing us the full allocation — value flows to nobody.
v1 shipped a manual pause; the product pitch ("pay while it's active")
needs the pause to be automatic and invisible to reverse.

Owner decisions settled on #203 (Oct 22):

- **1 hour** of no edge traffic is the idle threshold.
- Health probes and uptime monitors **must not count as traffic**.
- Cold start of **a few seconds** is acceptable UX — serve a waking page.
- **Sleeping bills storage-only** (the stopped rate — [ADR-0028](00028-flat-rate-pricing.md) §2).
- **Always-on is a paid premium** (never-sleeping as a flag; the billing
  tier is the open sub-decision below).

Prior art: Okteto's garbage collector — scale Deployments to 0, keep
PVCs/Services/ingress, requests wake the workload.

## Decision

### 1. `:sleeping` joins the state machine

`running → sleeping` (the idle sweep), `sleeping → starting` (wake — the
existing start lane; the reconciler stays the only writer of `:running`),
`:lost`/`:error`/`:deleting` compose unchanged ([ADR-0005](00005-customer-instances-as-namespaces.md)
Am. 3). Sleep is platform-initiated and traffic-reversible; stop stays
owner-initiated and owner-reversed — two different product verbs that
happen to share the cluster mechanics (scale 0, PVC/Service kept).

Billing rides the existing anchors untouched: leaving `:running` folds
the running interval, the storage anchor spans the sleep, so settlement
accrues storage-only for a sleeping row by construction — no
sleeping-arm exists in `settle_usage`, and runway burns the stopped rate.

### 2. Idle detection at the edge

A per-instance Traefik `forwardAuth` Middleware — the activity beacon —
consults the platform's `/internal/edge/touch` on **every** forwarded
request (the issue's "middleware writing per-instance last-used
markers"). The touch handler filters probe/monitor user-agents
(config-owned list), debounces (one `last_used_at` write per 30s window
per instance, however hot the traffic), and always answers 204 — a
beacon failure must never 500 an owner's app.

Rejected: **in-pod metrics** (the issue's constraint — asleep pods have
no metrics; the detector must live before the pod), **Traefik access-log
shipping** (no in-cluster log sink exists locally; local/prod parity
would fork), **scraping Traefik's Prometheus metrics** (more machinery,
and a scrape outage would *wrongly* sleep a busy instance — the failure
direction that puts owners' apps down).

Known trade, accepted: the beacon makes app serving depend on platform
availability (Traefik cannot fail open on forwardAuth). The platform is
a single-replica Deployment today; its availability incidents are
product-wide anyway. **Revisit trigger**: a platform outage that 500s
customer apps while they'd otherwise have served → move the last-used
signal to access-log ingestion or metrics scraping.

### 3. Sleep flips the edge routes

`SleepInstance` scales the Deployment to 0 (Okteto pattern), then
rewrites the instance's IngressRoutes to target a namespace-local
`wake` ExternalName Service pointing at the platform — visitors land on
the wake endpoint, not a connectionless Service. The rewrite needs
Traefik's `allowExternalNameServices` (deploy/local values; the fleet
repo's prod copy must carry the same line — **wake-on-use is dark in
prod until it does**). If the rewrite fails after a successful scale,
the row lands `:stopped` — the honest pre-#203 shape (traffic 503s, the
owner's Start works) rather than a sleeping row nobody can wake.

### 4. Wake is `start` plus a waking page

The wake endpoint (instance-host requests reach it through an
endpoint-level host plug — `FluxValeWeb.Plugs.EdgeHost` rewrites any
strict subdomain of the instances' base domain **carrying the
wake-marker header** onto a reserved `/_fluxvale_edge` prefix; a
router catch-all can't work, because an instance serves arbitrary
paths and several collide with real platform routes, and the marker
requirement is what keeps the platform's own same-domain host
untouched) keys off the platform-minted `X-FluxVale-Instance` header,
runs the same funded-wallet gate a member's Start would
(`ActorOrgWalletFunded`'s own predicate — the edge has no actor),
triggers `start`, and serves a
JS-free meta-refresh interstitial that re-requests the same URL until
the flip answers a redirect. Non-HTML clients (API callers, rclone) get
`503 + Retry-After` — the wake still triggers. Probes get a plain 503:
an asleep app **is** down to a monitor, and that is the honest answer.

The serving-route restore is request-driven (the first request that
finds the row `:running` re-applies the serving routes), not
promotion-driven: the reconciler stays read-only ([ADR-0005](00005-customer-instances-as-namespaces.md)),
and the placement is self-healing — a failed restore, an owner-clicked
Wake, a no-poller wake all converge on the next request.

### 5. Always-on

`always_on` is a member toggle on the instance page (stop/start's
org-membership posture); the idle sweep skips always-on rows. Sleeping
and waking never change a size's price
([ADR-0028](00028-flat-rate-pricing.md) — price = f(allocation)); always-on
is a billing-tier question, not a price change. The open sub-decision
(owner picks; surfaced in `docs/open-questions.md`):

- **Option A — flat surcharge**: a fixed monthly adder for the flag,
  pricing the density break explicitly. Needs a surcharge rate and a
  new accrual arm (follow-up PR).
- **Option B — 24/7 running-rate** (what shipping behavior bills today,
  by construction): an always-on instance simply never stops accruing
  the running rate; the premium emerges from what it doesn't do
  (sleep to storage-only). Zero new billing surface.

## Consequences

- The M5 zero-balance ladder ([#124](00029-payments-adapter-selfmor.md))
  composes unchanged: it stops `:running` rows, a sleeping row still
  accrues storage-only and still climbs the destroy ladder; the
  stranded sweep treats `:sleeping` like `:stopped` for loss detection.
- The idle sweep runs every 5 minutes; the 1-hour promise rounds to at
  most threshold + one cadence. A nil `last_used_at` on a running row
  never sleeps (unmeasurable fails open — an owner's app stays up).
- E2E shortens the threshold via `IDLE_SLEEP_AFTER_SECONDS`
  (e2e-bootstrap sets 180s; local-only — staging keeps the real hour).
- RBAC: the workload ClusterRole gains `traefik.io/middlewares` verbs;
  the beacon address rides the platform's own service DNS, namespace
  derived from `instance_rbac` (one config source).
