# ADR-0039: Private access layer — per-org Tailscale gateway (B1)

**Status**: Accepted (topology, provider boundary and billing shape settled
on #266/#268; the **price is not** — §5 proposes with cost basis, the
owner picks)
**Date**: 2026-10-26
**Issue**: fluxvale/fluxvale#268 (builds on #265/[ADR-0038](00038-instance-exposure-modes.md))

## Context

[ADR-0038](00038-instance-exposure-modes.md) made an instance `private`:
no route at the public edge, namespace ingress denied from it. Private
is the CVE kill-switch, but on its own it is a *closed* door — the owner
keeps the panel and loses the app. This ADR opens the door **through the
owner's own tailnet**, so FluxVale never becomes a VPN operator and never
sees the traffic.

Owner decisions settled on #266 (spike, four calls) and #268 (scope):

- **Topology B**: one gateway pod **per org**, running userspace
  `tailscaled` + `tailscale serve`, **zero pod privileges**. Rejected A
  (a sidecar per instance) — see §"Rejected alternatives".
- **B1 first**: one gateway hostname, **per-app ports** at root path.
  Auth key only; no console work per app. B2 (Tailscale Services, clean
  per-app hostnames) deferred.
- **Opaque gateway names** `fv-<short-uuid>`: serve + Let's Encrypt put
  the machine name in the public CT ledger; no app type, no org name.
- **Separate opt-in offering**, billed per gateway, priced by the owner.

The spike's evidence (headscale testbed, six userspace `tailscaled`
nodes) is the source of the facts below; each claim names its
experiment (E-numbers) or doc.

## Decision

### 1. One gateway pod per org, userspace, zero privileges

An `AccessGateway` row (org-scoped, at most one) materializes as a
Deployment in the platform's **access namespace** running the official
`tailscale/tailscale` image with:

| Env | Value | Why |
|---|---|---|
| `TS_AUTHKEY` | Secret ref, not a value | §4 |
| `TS_AUTH_ONCE` | `true` | a restart resyncs persisted state, it does not re-join |
| `TS_HOSTNAME` | `fv-<short-uuid>` | opaque name (CT ledger) |
| `TS_STATE_DIR` | PVC mount | identity survives restarts (E2.9) |
| `TS_SERVE_CONFIG` | Secret-mounted file | the routing table (§3) |
| `TS_ENABLE_HEALTH_CHECK` | `true` | status read (§2 `gateway_status`) |
| `TS_USERSPACE` | `true` (image default) | no `/dev/net/tun`, no `NET_ADMIN` |

`TS_USERSPACE` is the image default and Tailscale's own posture for
containers: the operator's userspace proxy pod carries **no
securityContext at all** (requests 1m CPU / 1Mi RAM), where its
kernel-mode sibling needs `privileged: true` init + main containers. The
spike confirmed the same boundary as a plain user: `--tun=<name>` fails
at `TUNSETIFF` (EPERM), `--tun=userspace-networking` serves with no
capabilities (E3a/E3b). Userspace needs nothing from Talos — no tun
module, no PSA exception. Cost is throughput ("lower performance" per
the docs), irrelevant at personal-app scale.

**No second container.** The gateway pod is the tailscale image alone;
the routing decisions live in the serve config the platform writes (§3)
and in the platform's wake endpoint (§6). The alternative — a
platform-owned proxy container in the pod — was rejected in
§"Rejected alternatives" because it makes FluxVale a data plane and adds
a second image to ship.

### 2. The provider boundary: `AccessProvider`

The seam #265 promised, implemented as one behaviour with one
implementation for now:

```elixir
@callback provision_gateway(gateway, credential) :: {:ok, gateway} | {:error, term}
@callback attach_instance(gateway, instance) :: {:ok, route} | {:error, term}
@callback detach_instance(gateway, instance) :: :ok | {:error, term}
@callback gateway_status(gateway) :: {:ok, status} | {:error, term}
@callback wake_intercept(gateway, instance) :: {:ok, :asleep | :awake} | {:error, term}
```

`gateway.provider` is an enum (`:tailscale`) and `credential_secret_ref`
stays an opaque string. `AccessRoute.route_key` is **provider-opaque**
(Tailscale: the allocated port; a WireGuard gateway would put a peer/host
mapping there). Nothing in billing, wake, panel or instance lifecycle
branches on the provider — the same shape that let HitPay land as one
adapter among future providers ([ADR-0029](00029-payments-adapter-selfmor.md)).

What stays Tailscale-specific and contained: auth-key intake UX, the
tag/MagicDNS/Enable-HTTPS onboarding page, serve-config templating, and
the mapping from observed gateway state to `:needs_attention`.

`gateway_status/1` reads the Deployment's readiness **and** the pod's
`/healthz` (`TS_ENABLE_HEALTH_CHECK`: 200 = the node holds at least one
tailnet IP, 503 = it does not). That answers the question the panel asks
— *is this gateway on the tailnet?* — with read-only verbs and no exec.
It does **not** distinguish "key rejected" from "tailscaled down"; both
render `:needs_attention` with the same "reconnect" action (re-paste a
key, or redeploy), which is honest for both. Revisit trigger: a support
case where the two need different copy — the upgrade is the LocalAPI
`status` (`BackendState`), which needs a pod-local proxy or `pods/exec`.

Gateway state machine: `:provisioning → :active ⇄ :suspended`, with
`:needs_attention` from `:active` (observed, not owner-intent) and
`:destroying` for teardown. `:suspended` is scaled to zero and accrues
nothing (§5).

### 3. Routing: one hostname, per-app ports, serve config as the table

`tailscale serve` is bound to the node's **one** MagicDNS name — the
config is keyed `"<node-dns-name>:<port>"`, has no hostname dimension,
and a request with any other Host header is a 404 (E2.1). So multi-app
on one node is **paths or ports**, and paths break apps that emit
absolute URLs. Ports do not: each port's mount point is `/`, giving
root-path semantics per app at a nonstandard port (E2.2). One cert
covers every port on the node.

An attached instance gets a port from the gateway's pool (8443+), and
the platform writes the whole serve config:

```json
{"TCP": {"8443": {"HTTPS": true}},
 "Web": {"fv-<uuid>.<tailnet>.ts.net:8443": {"Handlers": {"/": {"Proxy": "<target>"}}}}}
```

`<target>` is one of two static forms, and this is the whole routing
model:

- `http://<platform-svc>.<platform-ns>.svc.cluster.local:4000/internal/access/<gateway-id>/<instance-id>` — **asleep**
- `http://app.<instance-ns>.svc.cluster.local:80` — **awake**

The platform owns the config (it is a Secret it writes), so the flip is
an ordinary platform write; §6 says when it happens. Serve proxies to
arbitrary URLs — the operator's own ingress proxy points `Proxy` at
`svc.Spec.ClusterIP:port` — so no port-forward, no rewrite and no
data-plane process of ours sits in the path. Serve joins the visitor's
path onto the target's path (`SetURL`), so the asleep target keeps
`/repo/settings?x=1` intact and the wake page can refresh the same URL.

**Host passes through unchanged** (`r.Out.Host = r.In.Host`): the app
sees the gateway's `.ts.net` name, not a public hostname. That is why
private instances land well here — [ADR-0038](00038-instance-exposure-modes.md)
§4 already omits a catalog `instance_url_env` (Forgejo's `ROOT_URL`) for
a private row, so the app derives its own links from the request host
instead of emitting dead public URLs. Apps that hard-code a URL anyway
would emit links that only work on the public edge; v1 documents that as
a known limitation of B1 rather than adding a per-gateway URL override.

**Attach/detach are the pair to the exposure toggle** (#265's Availability
card): attach requires `exposure == :private` (a public instance already
has a public address; attaching would mint a second one), and detaching
returns the instance to panel-only, exactly today's private meaning.
Detach does **not** change exposure — the owner's two switches stay
independent, and the panel says which combination is live.

**The NetworkPolicy admits the access namespace, never the edge**
([ADR-0038](00038-instance-exposure-modes.md) §5's constraint): the
private policy's external list gains the gateway's namespace only while
an instance is attached, and loses it on detach. The edge entry stays
absent in every private state. An unattached private instance admits
nothing, as today.

### 4. The auth key lives in a Secret, never in Postgres

Per-gateway Secret in the access namespace: `TS_AUTHKEY` only. The row
stores `credential_secret_ref` (the Secret's name) and nothing else —
the backup-config pattern ([ADR-0037](00037-instance-backups-s3.md) §4),
not the `app-env` plaintext shape. The panel's input is a password-type
field; it writes the Secret and returns; no read-back path ever returns
the key. Re-paste = update the Secret + restart the pod (a fresh join
under the new key, same row).

Key shape is the user's to mint (onboarding doc): **reusable, tagged,
non-ephemeral**. Tagged nodes have node-key expiry disabled by default,
so the key is a join-time credential, not a runtime dependency: a
gateway killed and restarted on persisted state comes back Running with
the same identity and no key involved (E2.9). Keeping the key in the
Secret is what makes re-join possible (state lost, node deleted in the
console, key rotated) — `containerboot` re-auths from `TS_AUTHKEY` on
start when logged out.

### 5. Billing: existence accrual, and the ladder must see it

The gateway is a **flat monthly rate per gateway, billed hourly**, the
instance shape ([ADR-0028](00028-flat-rate-pricing.md)) without the
storage term:

- **Accrual** — `AccessGateway.PerformSettle`, the `perform_settle`
  discipline: wallet advisory lock first, fresh `FOR UPDATE` re-read,
  prorate the monthly rate over the open interval (micro-cents, average
  Gregorian month 2_629_746 s), `Billing.debit_wallet` (keyless — the
  anchor `metering_since` is the retry arbiter, exactly the instance
  contract), then advance the anchor. `EntryReason :usage` stays the
  dimension; attribution rides one **new nullable column**,
  `billing_ledger_entries.subject` (`"access-gateway:<id>"`), additive
  per [ADR-0013](00013-additive-migrations.md) exactly as the tax fields
  landed — every existing row stays null, no backfill, and the ledger
  gains no enum atom. The alternative (a `:gateway_usage` reason) was
  rejected: a new atom in the funding dimension would force every
  ledger reader to learn a second usage value to sum consumption.
- **`:suspended` accrues nothing** — the pod is at 0 replicas, the
  anchor is parked. Same as a stopped instance's running stream.
- **The MUST-FIX from the spike** (found by reading the repo, not
  guessed): `ComputeRunway` and `SweepZeroBalance` count instances only.
  A gateway debit invisible to burn would let runway over-estimate, and
  the ladder's stop arm would never suspend a gateway. Both are extended
  here: burn adds every `:active` gateway's rate, and the ≤0 arm
  suspends gateways alongside instances. Resuming is the owner's, gated
  on the funded wallet — `start`'s own contract, no new machinery.
- **Opt-out is teardown**: destroy the gateway (pod, Secret, PVC) and
  stop accrual; the instances fall back to panel-only private.
  Exposure itself stays free ([ADR-0038](00038-instance-exposure-modes.md) §5).

**The price is the owner's.** Cost basis and the proposed bands are in
§"Cost basis" — the issue forbids this lane picking a number.

### 6. Wake: the platform is the asleep target, and the first request flips it

A gateway request for a sleeping instance must wake it, with the panel's
authorization, and be indistinguishable at the metrics level (#232).
Private instances have nothing at the public edge, so the gateway is the
only thing that can notice.

Mechanism: **while asleep the serve target is the platform's wake
endpoint; the request that finds the instance `:running` rewrites the
serve config to the app and keeps serving the waking page until the
config lands.** Concretely:

1. Visitor opens `https://fv-…:8443/` → serve proxies to the platform's
   `/internal/access/<gateway-id>/<instance-id>` (the visitor's path and
   query append to it, so a deep link survives).
2. The platform authorizes the **pairing**, not the caller: it looks up
   an `access_routes` row for exactly this (gateway, instance) whose
   gateway is `:active` and whose instance is `:private` and same-org.
   That row *is* the owner's consent — the org opted into this gateway
   and attached this instance to it — so the wake needs no second
   credential and the endpoint grants nothing panel-shaped. An
   unattached, cross-org or suspended pair gets a 404 identical to an
   unknown one. (The endpoint is in-cluster-only, reachable by the
   gateway pod; the pairing check is what holds if anything else in the
   cluster reaches it, and a compromised app forging a pair can at most
   start an instance its own org already pays for — which the public
   wake endpoint already allowed before #265 gated it.)
3. `:sleeping` → `Infrastructure.wake_instance/1` (the funded gate and
   `start`; the panel's own path) → the waking page, 2s meta-refresh.
4. On a later refresh that finds `:running` → write the serve config's
   target for that port to the app Service; keep serving the page.
5. The mounted config updates, `containerboot` re-applies it (the
   operator carries serve config in a mounted Secret the same way), and
   the next refresh lands on the app — at the URL the visitor asked for,
   because the sleep target's path was a prefix.

`wake_requested_at`/`wake_promoted_at` ride the existing start lane
untouched — a gateway wake is a wake.

What this is **not**: "refused-backend detection". A *running* app whose
container died keeps the app target, and serve answers 502 — correct,
because there is nothing to wake. The asleep case never produces a
refusal to detect, because the target *is* the platform while asleep.
Rejected: a proxy container in the pod that catches refusals (a second
image, FluxVale in the data path, and per-request proxying of uploads
and websockets through our code), and the platform proxying app traffic
outright.

**Known cost, stated plainly**: the flip lands when the mounted Secret
reaches the pod — seconds in the common case, up to the kubelet's sync
period in the worst. The wake page is honest through that window ("still
waking"), and the flip is request-driven, so a missed one converges on
the next refresh (the `RestoreServingEdge` stance). Revisit trigger: a
measured flip above ~10s in staging — then the fallback is a pod
restart on flip (a few seconds of tailnet reattach, state persisted).

### 7. The stale-sleep window ([ADR-0038](00038-instance-exposure-modes.md) §6) is closed here

[ADR-0038](00038-instance-exposure-modes.md) §6 left one window open and
handed it to this lane: an idle-sweep sleep that loaded a **public**
row can mint a **wake-mode** route after the owner's toggle to private
committed, because `:sleep` accepts no attributes — no `UPDATE`, no row
lock before `EdgeRoutes.apply_wake` — and `set_exposure`'s optimistic
lock only ever contends with other toggles.

Fix: **the sleep takes the row lock and adopts the current row before it
decides anything.** `:sleep` gains the same `before_action` the deploy
uses ([`AdoptCurrentRow`](../../apps/platform/lib/flux_vale/contexts/infrastructure/resources/instance/adopt_current_row.ex)):
re-read the row `FOR UPDATE`, swap it into the changeset, cancel if it
vanished. This works because an Ash update's `before_action` runs inside
the action's own transaction (verified, not assumed: `Repo.in_transaction?`
is true there for both an attribute-accepting action and an `accept([])`
one, and a row adopted in `before_action` is the record `after_action`
receives). The K8s applies run in `after_action`, inside that same
transaction — so the two writers serialize on the row:

- toggle first → the sleep's locked re-read sees `:private` → the private
  dispatch deletes routes and mints nothing;
- sleep first → the toggle blocks on the row, then applies private to a
  settled world and deletes the wake route.

Either order converges; no mint survives a private row.

The tradeoff, stated: the sleep now holds a row lock across two K8s
calls (scale + route apply), so a concurrent toggle can wait seconds
rather than racing. That is the price of correctness here and the same
price the deploy and toggle pair already pays. Rejected: an exposure
check at mint time (leaves a check-to-write window and gives the toggle
no serialization point), and a reconciler pass (the reconciler is
read-only by [ADR-0005](00005-customer-instances-as-namespaces.md)'s
split, and edge state would gain a third automaton that the owner's
panel cannot explain).

Ancillary change, same fix: a row that left `:running` between the
sweep's batch read and the sleep now lands `:sleeping`/`:private`
instead of erroring. The private dispatch is idempotent, so the sleep is
correct when the private posture already holds.

Proven by a test that fails without it: sleep a row whose struct still
says `:public` after the row itself went `:private` — the production
race, since the sweep passes the pre-toggle record — and assert no
wake-mode route is minted.

### 8. Limits accepted for v1

- **One gateway per org** (the row is org-scoped and unique). A second
  tailnet for the same org is not a v1 product shape.
- **No B2**: per-app hostnames via Tailscale Services need console or
  API objects and tag approvals per Service — deferred until demand and
  an OAuth-grant decision (owner's).
- **A user deletes the node in their console** → the gateway reads
  `:needs_attention`, and re-paste (or a redeploy) rejoins. No console
  API access, so the platform cannot repair it itself.
- **Tailnet prerequisites are the user's**: tag + `tagOwners`, MagicDNS,
  and **Enable HTTPS** on the DNS page (which carries the public-CT
  acknowledgment). The onboarding page walks all three; the panel cannot
  do them.
- **Fleet work is reported, not done**: the access namespace, its quota
  and PSA labels, and the platform SA's RBAC on gateway Deployments,
  Secrets and Pods live in the private fleet repo.

## Rejected alternatives

- **A — a Tailscale sidecar per instance.** Its one genuine win is a
  clean per-instance hostname with only a key. It loses on the product
  requirement: **wake-on-use is structurally impossible**, because the
  access path (the sidecar) is scaled to zero with the pod, so the
  request that should wake the app can never arrive (E2.8: the ephemeral
  node is auto-removed and comes back `Logged out`). It also spends a
  device slot per instance (against the tailnet's 50 free tagged
  resources), churns node identity, and bills per instance where the
  owner steered to a per-user offering. Kept as the documented fallback
  for a future "instance directly on your tailnet" premium mode.
- **B2 now — clean per-app hostnames via Tailscale Services.** Same
  gateway, N named services: strictly nicer URLs than ports, but every
  Service must be defined in the admin console or by an OAuth client the
  owner grants us, hosts need tag identity and approval, and clients need
  ≥1.94. That is console work per app, which is the friction B1 exists to
  avoid. Deferred, not rejected on merit.
- **A platform-owned proxy container in the gateway pod.** Correct
  per-request behaviour (catch a refusal, call the wake endpoint, hold the
  connection), but it puts FluxVale in the data path — uploads,
  websockets and streaming through our code — and adds a second image to
  build, pin and ship, with its own language, review burden and coverage
  story outside this repo's rules. §6's route swap gets the same product
  outcome with a platform write instead.
- **The platform as the tailnet data plane** (serve targets the platform
  for every request, the platform reverse-proxies the app). Simplest
  wake story, worst architecture: one pod becomes the private path for
  every org, and a platform deploy drops every tailnet session.
- **Path prefixes per app on one port** (`--set-path=/kavita`). No extra
  port, but apps that emit absolute URLs (Kavita, Forgejo class) break.
  Ports give root-path semantics with one cert.
- **Per-instance devices, ephemeral keys, Funnel, Cloudflare Access.**
  The first two are topology A's costs; Funnel is public by definition
  (the opposite of private); Cloudflare is out by the owner's Oct 26
  decision and adds a trust dependency this lane does not need.

## Cost basis (the owner picks the number)

Platform cost per gateway, from the shipped density model
([pricing-calibration](pricing-calibration.md): RS 4000, €87/mo rolling
≈ **$103.64/mo lean** / $118.64 full, ~24 GB active RAM / 12 cores /
≈460 GB usable).

A userspace gateway requests **1m CPU / 1Mi RAM** (the operator's own
userspace proxy template — the shipped request, not a guess) and in
practice holds tens of megabytes of RSS: userspace networking + serve is
a Go process with a WireGuard engine. The table below prices **64 MB as
the conservative ceiling** — twice the middle of the 32–64 MB band the
#266 notes carry — so the estimate errs high. It uses **no storage**
(state is kilobytes; a 64Mi PVC is ample).

| Term | Basis | Per gateway / month |
|---|---|---|
| Memory | 64 MB of 24 GB = 0.27% of the box's $103.64 | **$0.28** |
| CPU | 5m of 12 cores ≈ 0.04%, oversubscribed and bursty | ~$0.04 |
| Platform work | serve-config writes, wake-page hits, status reads | < $0.01 |
| Egress | through the user's own tailnet, not our edge | **$0.00** |
| Tailscale | the user's plan (free Personal: 6 users, unlimited user devices, 50 tagged resources) | **$0.00** |
| **Total platform cost** | | **≈ $0.33** |

The real cost is not the box, it is **support surface** (auth keys, tag
policy, Enable HTTPS, console drift) — a per-gateway price buys headroom
for that, not for compute.

Proposed bands (owner's pick; per gateway, monthly-equivalent, billed
hourly like every other rate):

| Band | Price | ≈× cost | Reads as |
|---|---|---|---|
| A | $1.00 | 3× | "throw-in" — near-free add-on; under-signals that it costs us anything |
| B | $2.00 | 6× | **proposed**: covers the gateway and its support share, still under every instance tier |
| C | $3.00 | 9× | priced as a feature tier; may suppress opt-in for a 1–3 instance org |

Numbers are the owner's. What the lane pins either way is the *shape*:
per gateway, monthly-equivalent, hourly accrual, no storage term,
suspended at zero balance, exposure itself never charged.

## References

Serve/naming semantics and the experiments, from the #266 spike
(ops task notes; placeholders only — no real tailnet names): E2.1
Host-header 404, E2.2 port-root mount, E2.3 the serve-config JSON shape,
E2.4c headless apply, E2.5 expired key, E2.8 ephemeral auto-removal,
E2.9 non-ephemeral restart without a key, E2.10 gateway→dead backend
502; E3a/E3b the privilege boundary.

- tailscale.com/kb/1242/tailscale-serve — serve flags, path/port
  semantics, one node one name; /docs/features/tailscale-services —
  Services prerequisites (B2's cost); /docs/concepts/machine-names —
  unique names, renaming, CT visibility
- tailscale.com/kb/1085/auth-keys — 1–90d expiry, reusable/tagged,
  "device remains authorized until its node key expires";
  /kb/1068/acl-tags — tagged nodes' key expiry disabled by default,
  `tagOwners`; /kb/1111/ephemeral-nodes; /kb/1153/enabling-https — the
  Enable HTTPS gate, CT acknowledgment, 90-day certs
- tailscale.com/kb/1282/docker + /docs/features/containers/docker/docker-params
  — `TS_USERSPACE` default true, `TS_AUTHKEY`/`TS_AUTH_ONCE`/`TS_STATE_DIR`/
  `TS_SERVE_CONFIG` (watched, `${TS_CERT_DOMAIN}` substituted)/
  `TS_ENABLE_HEALTH_CHECK`/`TS_HOSTNAME`; /kb/1112/userspace-networking
- tailscale.com/docs/kubernetes-operator/ingress (+
  expose-workload-to-tailnet-l7) — ProxyGroup, per-Ingress hostnames,
  userspace serve proxies, serve config in a mounted Secret
- tailscale/tailscale@main: `cmd/k8s-operator/deploy/manifests/userspace-proxy.yaml`
  (no securityContext), `proxy.yaml` (privileged kernel mode),
  `cmd/k8s-operator/sts.go` (`TS_SERVE_CONFIG`, mounted Secret volume),
  `cmd/k8s-operator/ingress.go` (`Proxy` = `http://<ClusterIP>:<port><path>`),
  `ipn/ipnlocal/serve.go` (`HTTPHandler.Proxy` accepts any URL),
  `cmd/containerboot` (`TS_SERVE_CONFIG` watched; `${TS_CERT_DOMAIN}`)
- Repo seams: `infrastructure/resources/instance/perform_settle.ex` (the
  settle discipline this mirrors), `billing/operations/compute_runway.ex`
  + `sweep_zero_balance.ex` (the ladder this extends),
  `infrastructure/operations/edge_routes.ex` (the route flip this
  follows), `instance/adopt_current_row.ex` (the lock-and-adopt shape §7
  reuses), `operations/configure_backups.ex` (the Secret-as-home pattern)

## Amendment 1 (2026-10-26): §7's lock waiters, its private-posture wording, and the landing order

§7 as accepted describes the fix and its tradeoff but leaves three
things imprecise. Corrected here, with the decision text above left
intact.

**Landing order.** §7 asserts a window "is closed"; the code that closes
it is its own PR (#270), not the ADR's. The assertion holds only because
#270 merged first (`8d3eb92`, before the ADR's own `d52a836`) — read this
ADR as describing a fix in the tree, not as a proposal.

**The lock's waiters.** §7 names only the toggle as the writer that can
wait. It is five: the toggle, the edge beacon's `:touch` (the idle-clock
write, at most once per 30s window per instance), the reconciler's status
write (every minute per instance), settlement's anchor advance (every
15 minutes), and the panel's Wake (`:start`).

Scope the claim correctly — two of those five do cluster I/O *before*
taking the row lock (`:reconcile_status` reads the Deployment, `:start`
scales it), so their total wait behind a sleep is that I/O plus the lock,
not "seconds". What is established is narrower and is all that matters
here: **no cycle exists in the lock order** (the sleep takes no wallet
lock; settlement takes the wallet lock before the row lock everywhere),
so a wait always ends in a commit, and the sleep is the only one of the
five holding the row lock across its own K8s calls.

**The private-posture wording.** §7 says a row that left `:running` in
the gap "now lands `:sleeping`/`:private` instead of erroring". Two
corrections, in opposite directions:

- A row that is `:private` when the sleep's locked re-read lands is still
  slept (`:running → :sleeping`) under the **private posture** — routes
  deleted, nothing minted. That is the fix working; the clause is right
  about the outcome and loose about the transition.
- A row that a *different* writer moved off `:running` in the gap is
  **not** a quiet no-op: the sweep's own fresh re-read (`still_idle?/1`)
  skips it inside `safe_sleep/1`, but if the row moves *after* that read,
  the sleep action's status guard adds a changeset error, `safe_sleep/1`
  logs it and returns `{:error, id}`, and the pass fails as a unit for
  Oban's retry. The retry is correct (nothing was slept, nothing leaked);
  the wording "instead of erroring" was wrong.
