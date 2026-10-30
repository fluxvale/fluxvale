# ADR-0040: Strong private access and custom domains — one resolution-keyed system

**Status**: Accepted (PA design gate, 2026-10-30, all eight open decisions
ruled on and folded into the text below; the per-domain price was set by
the owner in-session. Implementation pre-authorized; this document lands
as the product ADR PR before the first implementation slice.)
**Date**: 2026-10-30
**Issue**: [fluxvale/fluxvale#320](https://github.com/fluxvale/fluxvale/issues/320) (builds on #265/#268/#273, and on the
serve-config correction lane in flight at drafting time)
**Supersedes**: nothing; extends [ADR-0038](00038-instance-exposure-modes.md)
and [ADR-0039](00039-private-access-layer-tailscale.md). Amends the B1
routing decision of ADR-0039 §3 for the custom-hostname arm only; the
ts.net fallback arm is unchanged.

## Summary (plain language)

Today a private app is reachable only as
`fv-xxxx.tailnet.ts.net:8443` — a second, uglier URL. This ADR makes the
app's **normal address** (`myapp.fluxvale.app`, or `myapp.terence.dev`, or
`wiki.fluxvale.com`) work **unchanged** on the owner's tailnet:

- On the tailnet, that hostname resolves to the org's gateway, the
  connection tunnels through the gateway pod, and our in-cluster edge
  presents a real certificate for the hostname. Off the tailnet, a private
  app's address stays dark — that is the security posture, unchanged.
- A domain is usable privately after a **one-time-per-tailnet claim**: we
  add a split-DNS route for the domain in the customer's Tailscale (via
  API), pointing at a FluxVale resolver that only tailnet members can
  reach. That claim needs a Tailscale API key or OAuth grant with DNS
  scope — the first time we ask for tailnet-level power beyond a join key,
  and the biggest trust decision in this document.
- Future customers keep their DNS: they add one CNAME for the hostname and
  one delegation of `_acme-challenge` to a FluxVale zone. We never hold
  their DNS credentials. Certificates are issued and renewed from that
  delegation alone.
- One architecture serves all three of the owner's own cases (personal
  domain, fluxvale.com, fluxvale.app default) and the future-customer case.

What it does not do: it does not add per-user authentication (tailnet
membership is the boundary, as in ADR-0039); it does not make private apps
resolvable off-tailnet; Linux tailnet members must accept subnet routes
(one client setting) for the resolver to be reachable.

## Context

ADR-0039 shipped B1: one gateway pod per org, userspace `tailscaled` +
`serve`, per-app **ports** at root path, keyed by the node's single
`.ts.net` MagicDNS name. First live use surfaced the two-URL friction
(owner smoke session, Oct 30): the ts.net port address works but nobody
wants to type it, and the public subdomain goes dark when private —
correct per the walls posture, but the same-app-two-addresses split is the
remaining UX debt. The owner decided in-session: the **strong** version
("I definitely want the strong version") — the tailnet resolves the real
hostname and the gateway serves the original name — as **one system** with
custom domains, because both are the same problem: *serve a hostname we do
not control the DNS of, to a device set we do control resolution for.*

Three facts from outside the repo shape the design (verified against
source/docs, Jan 2026 vintage):

1. **`tailscale serve` cannot present third-party certificates.** The TLS
   path in `ipn/ipnlocal/serve.go` is exclusively
   `getTLSServeCertForPort → GetCertPEM(ServerName)` — Tailscale's own ACME
   provisioner, which answers DNS-01 via `.ts.net` TXT records only. There
   is no `--tls-cert` flag, no cert-file field in `ipn.ServeConfig`, and
   the CLI docs (validated Jan 2026) list none. A `Web` entry keyed by a
   non-`.ts.net` hostname passes the SNI lookup but **fails at
   certificate time**. Any design that assumed "put our cert on the
   gateway, key serve by custom hostname" is dead on arrival — including
   the version sketched in the smoke-feedback note.
2. **Serve's raw TCP forward is the escape hatch.**
   `"TCP": {"443": {"TCPForward": "<target>"}}` forwards uninterpreted
   bytes — TLS included — to any URL the node can dial, and TCPForward
   rides the same userspace dial path as `Proxy` (the k8s operator's
   ingress proxies work exactly this way). Terminate TLS ourselves behind
   the forward and serve can carry any hostname, any cert.
3. **Split DNS is a tailnet-global API surface.** The tailnet DNS config
   (`/api/v2/tailnet/{tailnet}/dns/nameservers`, `dnsRoutes` family) is a
   whole-tailnet replace-on-write object; our writes must merge with any
   routes the customer already has. Route approval for the resolver's
   subnet route is a second API surface (`/api/v2/device/{id}/routes`).
   Both need a token with `dns` + `routes` scopes — more on the trust
   analysis in §Security.

Inside the repo, three pieces of prior art make this cheap:

- **The edge already holds a `*.fluxvale.app` wildcard** in a Traefik
  default TLSStore (fleet #116, cited in
  `Clients.K8s.Resources.Ingress`) — the default-domain arm of this ADR
  needs **zero new certificate machinery**.
- **The `Ingress` wrapper already supports full-host routing** (`:host`,
  `:tls_secret_name`, `:cert_resolver`) — "custom domains … the path is
  ported ready" ([ADR-0031](0031-build-order.md)'s post-beta deferral).
- **DNS-01 via a Cloudflare cluster-issuer is already a documented fleet
  pattern** (the thalmyra overlays) — the custom-domain arm reuses it
  with a CNAME-delegated challenge zone.

The owner's driving case, concretely: his personal instances on his
personal domain, FluxVale company instances on `fluxvale.com` subdomains,
everyone else on `fluxvale.app`. All three domains are his; the
future-customer path is the standard ACME DNS-delegation pattern (customer
CNAME + `_acme-challenge` delegation into a FluxVale zone, never
credential handover).

## Decision

### 1. Architecture: the gateway becomes a tunnel; the edge terminates

Strong private access is **a raw TCP forward from the gateway's tailnet IP
to a new `access` entrypoint on the existing Traefik edge**, which routes
by hostname and presents certificates from Kubernetes secrets:

```
tailnet device
  └─ https://myapp.fluxvale.app  (normal URL, port 443)
       DNS: split-DNS route (claimed once per tailnet+domain)
            → FluxVale resolver (reached THROUGH the gateway's /32 subnet route)
            → answers the gateway's tailnet IP
       TCP:  device → gateway pod (userspace tailscaled)
            serve "TCP 443 → TCPForward <access-edge>:443"   [raw, no TLS interp]
            → Traefik `access` entrypoint (NetworkPolicy: gateway pods only)
            → IngressRoute Host(`myapp.fluxvale.app`) on entrypoint `access`
            → app Service (awake) or platform wake endpoint (asleep)
```

The gateway pod stays exactly ADR-0039 §1: official image, userspace,
zero privileges. Its serve config gains one static tunnel limb (TCP 443,
and 80 for redirects, → the access edge) and **keeps every existing
per-app `Web` entry on `.ts.net:844x` unchanged** — the ts.net port
address remains the fallback that works with no domain claimed, no API
token granted, nothing but the join key (ADR-0039's B1 promise, intact).

What moves where, versus ADR-0039 §3:

| Concern | ADR-0039 (ts.net arm) | This ADR (custom-hostname arm) |
|---|---|---|
| Routing table | serve config Secret (per-app ports) | Traefik IngressRoutes on `access` entrypoint (per hostname) |
| Certificate | Tailscale ACME (`.ts.net`) | cert-manager DNS-01 → k8s Secret → Traefik |
| Wake routing | serve target flips platform↔app | IngressRoute flips wake-target↔app-service |
| Tailnet prerequisites | join key, Enable HTTPS | those, **plus** one-time route approval + split-DNS claim (API token) |
| Port allocation | per attached instance | not needed (hostname-keyed, port 443) |

This deliberately narrows the provider seam. Under B1 the provider owned
the routing table; here the provider (Tailscale) owns **join, tunnel, and
name resolution**, while hostname routing returns to `EdgeRoutes` — the
platform's existing, provider-agnostic edge system. A future non-Tailscale
access provider would bring its own tunnel + resolution claim and land on
the same access entrypoint. (Both fleet shapes ruled at the gate: the
SAME Traefik deployment gains the `access` entrypoint — the NetworkPolicy
invariant is test-pinned, and a second deployment would be isolation the
policy already provides; the resolver is CoreDNS.)

**Why this is not the "platform as data plane" rejection of ADR-0039.**
The rejected alternative proxied all app traffic through a platform pod.
Here app traffic still terminates at the app's own Service (or the shared
Traefik the public path already crosses — in the same cluster the app
lives in). What is new on the private path is one hop through the
customer's own gateway pod (their tailnet, their device relationship) and
one through an edge deployment we already operate for every public
request. No platform deploy drops tailnet sessions: the tailnet session
lives on the gateway pod; an access-edge restart drops individual
connections, which re-dial, exactly like public traffic today.

### 2. The domain registry: verify-by-issuance

A new org-scoped resource, `AccessDomain`:

- `domain` — the registrable-ish zone we answer for (e.g.
  `fluxvale.app`, `terence.dev`, `apps.customer.com` — a **subzone** is
  the unit for customers, see §4).
- `state`: `:pending → :verified ⇄ :suspended`, plus `:failed`.
- `challenge` data: the delegation records we need (one CNAME for the
  host prefix, one `_acme-challenge` CNAME), rendered for copy-paste.
- `cert_secret_ref` — the cert-manager Secret once issued.

**Verification is certificate issuance, nothing else.** The registry row
promotes `:pending → :verified` only when cert-manager successfully
completes a DNS-01 issuance for the delegated name. A successful DNS-01
through the CNAME delegation is cryptographic proof the customer controls
the zone's `_acme-challenge` — that is the entire point of the pattern,
and it doubles as a liveness probe forever after (renewal failure flags
the domain `:needs_attention`, never silently). No email validation, no
TXT-token dance of our own, no "we'll trust the CNAME exists" resolution
check. Issuance failure after N days (LE retries) → `:failed` with the
honest copy.

The platform's own domains (`fluxvale.app`, and FluxVale's other zones)
are seeded `:verified` — we hold their Cloudflare zones; their wildcard
already exists.

**Private-first** (ruled at the gate): this lane ships custom domains
private-on-the-tailnet only — `fluxvale.com` subdomains serve through the
owner's tailnet at their real hostnames from day one. Public custom-domain
serving ([ADR-0031](0031-build-order.md)'s deferred feature) is its own follow-up slice when the
owner wants it; the registry serves both, sequencing is the only
difference.

Hostnames: an `InstanceHostname` row per (instance, domain) — `label +
domain`, unique per domain, DNS-label-validated (the `Ingress` wrapper's
existing grammar). Every instance keeps its default
`<slug>.fluxvale.app` hostname (created today, renamed nothing); custom
hostnames are additional rows. The public edge's future custom-domain
serving ([ADR-0031](0031-build-order.md)'s deferred beta-later feature) reads the **same
registry** — one source of truth for "which hostnames exist", consumed by
both entrypoints.

### 3. Split-DNS claiming: one-time per tailnet, per domain

Claiming a domain on a gateway's tailnet does two things, once, via the
Tailscale API (token intake in §5):

1. **Approve the resolver's subnet route.** The gateway advertises a /32
   — the ClusterIP of the shared access-DNS Service, a static IP reserved
   from a fleet-reserved slice of the service CIDR. We look up our node
   by its `fv-` hostname and set its enabled routes. Clients that accept
   routes (all platforms but default-off Linux) now route exactly one
   cluster IP through the tailnet.
2. **Add the split-DNS route.** `PATCH
   /api/v2/tailnet/{tailnet}/dns/split-dns` with
   `{"<domain>": ["<access-DNS ClusterIP>"]}` — the endpoint is a
   **native per-domain upsert** (spike-pinned against the official SDK
   v2.12.0: domains not included remain unchanged; a nil value unsets),
   so claiming and un-claiming our domains needs no read-modify-write
   and cannot race the customer's other split-DNS edits. A route we
   already own is converged, not duplicated. If another FluxVale gateway
   on the same tailnet (second org, shared tailnet — the owner's case)
   already claimed the domain, the claim is a no-op: **one route per
   (tailnet, domain), regardless of how many gateways ride it.**

Route approval is the one replace-semantics surface (`POST
/api/v2/device/{id}/routes` replaces the enabled list): claim takes the
read→union→write shape there, and can **pre-enable the route before the
gateway ever joins** (the API explicitly supports enabling
non-advertised routes).

Field-level shapes above are pinned (the S0 spike against the official
SDK v2.12.0 and the current trust-credentials reference);
live writes still need the token intake of §5.

Claim records live on the gateway row (`dns_claims`: domain list +
tailnet identifier + last-observed config hash), so drift is observable
and re-claim is idempotent. Un-claiming (domain detached from the org's
last gateway on that tailnet) removes our route with the same PATCH
(nil value).

**Default-on for the base domain** (ruled at the gate): a gateway whose
tailnet has a token claims `fluxvale.app` automatically — the owner's
default experience is the point; custom domains claim on registration.

Exact request/response field names are pinned in the slice-0 spike against
the live API reference; the endpoint families above are stable and the
merge/claim/unclaim semantics are what the product depends on.

### 4. Resolution: a FluxVale resolver on the tailnet, per-gateway views

The `access-dns` Deployment (CoreDNS; the `view` plugin) lives in the
access namespace, one per cluster, reached only through the gateway subnet
routes. It serves, **keyed by the source gateway pod IP** (the query
arrives from the gateway that tunneled it):

- For each domain claimed by that gateway's org: a zone where
  - hostnames of **attached, private** instances answer
    `A <that gateway's tailnet IP>`,
  - everything else — public hostnames, unknown names — **forwards to
    public recursion** (`forward . 1.1.1.1`), so public instances keep
    working identically on tailnet devices, and no hostname is dark that
    shouldn't be.
- Nothing else: no recursion open to the tailnet beyond claimed domains'
  zones plus the forwarded remainder of those zones, no caching of
  cross-customer data, per-gateway views so org A's hostnames never answer
  for org B's gateway-sourced queries (a hostname answered through the
  wrong gateway would be unroutable anyway — different tailnet IP space —
  but existence itself is scoped too).

The platform renders each gateway's view as data (a ConfigMap the
deployment watches) — the same "routing table as a Secret/ConfigMap the
platform writes" posture as the serve config, no FluxVale data-plane code
in the resolver.

**Why a resolver at all** (vs. the alternatives, each dead or worse):
Tailscale has no per-tailnet custom DNS records API we could write
hostnames into (ExtraRecords exists as a tailnet-wide static set — see
Rejected); MagicDNS answers `.ts.net` only; a public FluxVale resolver
cannot distinguish member devices from strangers (their queries arrive
from home NATs, not tailnet IPs) so it would answer private hostnames to
anyone — the existence leak the walls posture forbids; DNS-over-TCP alone
fails because clients' forwarders only fall back on truncation, never on
timeout. A resolver reached **through** the tailnet is the only shape
where membership is the gate, by construction.

**The honest cost**: DNS queries for claimed domains now transit FluxVale
code, and we *could* log them. ADR-0039 said "FluxVale never sees the
traffic" — resolution metadata is a real, narrow retreat from that
sentence, knowingly accepted: query logging stays off, the resolver
retains nothing, and the posture note in §Security says so plainly.

Client caveat, stated for onboarding copy: Linux members must enable
`--accept-routes` (macOS/Windows/GUI clients accept by default); without
it the resolver IP is unrouted and claimed domains fall back to public
resolution (dark for private apps — degraded, not broken, and the ts.net
fallback address still works).

### 5. Credentials: what we ask the customer to grant

B1 asked for one **auth key** (join-time only, no tailnet read). Strong
needs tailnet-level API power, once per tailnet, for claiming:

(Ruled at the gate: API key first, OAuth at self-serve.)

- **v1 intake**: a Tailscale **API key** with `dns` + `devices:routes` +
  `devices:core:read` scopes, pasted once per tailnet into the access
  settings. Stored as a Secret, ref-only on the row — the ADR-0039 §4
  discipline (the backup-config pattern, never Postgres, never a
  read-back). **API keys expire ≤90 days by design** (spike-pinned):
  v1 intake carries a built-in rotation burden — the panel shows key
  age, and the drift observer treats a 401 as `:needs_attention` with
  re-paste copy (expired and revoked present identically).
- **Self-serve later**: an **OAuth client grant** — client credentials
  with no fixed expiry, revocable by the customer without touching us,
  and (spike finding) **capable of registering nodes directly**
  (`--auth-key='${OAUTH_SECRET}?ephemeral=false&preauthorized=true'`).
  One OAuth credential with `dns + devices:routes + devices:core:read +
  auth_keys` scopes could serve gateway join, route approval, AND
  claiming — the self-serve intake should be designed around that single
  credential from the start. The ADR-0039 §8 "OAuth-grant decision
  (owner's)" is forced here: the strong form cannot ship without
  *some* dns-scoped credential.

The blast radius of a dns+routes token is analyzed in §Security; the
design constraints on our side are: minimal scopes, merge-only writes,
idempotent re-claims, every write logged to the org's audit trail, and
the customer can revoke the token at any time (our row observes
`401`s and flags the gateway `:needs_attention` — honest degradation:
claimed domains fall back to public resolution; the ts.net fallback keeps
working; nothing breaks silently).

### 6. Certificates: DNS-01 via delegation, wildcard-of-subzone

**FluxVale-owned domains** (`fluxvale.app` and siblings): the existing
fleet wildcard (`*.fluxvale.app` in the Traefik default TLSStore) serves
the `access` entrypoint unchanged. Renewal is the fleet's existing
cert-manager job. Zero new machinery.

**Customer domains** (including the owner's "personal domain" case, which
uses the customer path deliberately — one pattern, no special-casing):
the standard delegation pair, rendered as copy-paste records:

```
host:    myapp.apps.customer.com     CNAME  <edge-or-access-target>.fluxvale.app
challenge: _acme-challenge.apps.customer.com  CNAME  <token>.acme.fluxvale.app
```

- The **challenge CNAME** is zone-level for the subzone the customer
  delegates (`apps.customer.com`), because we issue a **wildcard
  `*.apps.customer.com`**. Cert-manager's DNS-01 solver follows CNAMEs;
  the TXT lands in our `acme.fluxvale.app` zone on Cloudflare, written by
  the same token class the thalmyra overlays already document. We never
  hold a customer DNS credential, and renewal is automatic forever after.
- The **host CNAME** exists only for the *public* serving of that
  hostname (future public custom domains). A **private-only** custom
  domain needs no host record at all: the hostname resolves only through
  the claimed tailnet. That is the maximum-invisibility shape and the
  default we offer.

**Wildcard vs per-hostname, decided**: wildcard-of-delegated-subzone,
everywhere we can.

| | Wildcard `*.zone` | Per-hostname certs |
|---|---|---|
| CT ledger | no hostnames revealed | **every hostname published** (walls-lane regression; ADR-0039 §1's opacity logic applies to instance names too) |
| LE limits | 1 cert/domain; renewal headroom applies | **50 new certs per registered domain per week** — disqualifying for `fluxvale.app` at fleet scale |
| Delegation | one zone-level CNAME | one CNAME per hostname (more customer work) |
| Key blast radius | one key impersonates the whole subzone | one key per hostname |

Per-hostname is **not a self-serve shape** (ruled at the gate): it exists
only as a documented **support-path exception** for customers who cannot
delegate at subzone level, with the CT cost stated — never a product
surface the panel offers.

**Where certs live**: Kubernetes Secrets at the edge (Traefik's namespace,
or the access namespace with Traefik granted read) — **not on the gateway
pod**. This deviates from the "certs mounted to the gateway" sketch and
is the better trade: serve cannot present foreign certs at all (§Context
fact 1), and keeping private keys out of the gateway pods means a
compromised gateway holds no key material — the ts.net fallback certs are
Tailscale-managed on the node, ours never touch it. Renewal: cert-manager
(~30d before expiry), Traefik reloads on Secret change, alert on
`cert_manager_certificate_renewal_errors` (existing metrics plumbing).

DNSSEC caveat: a DNSSEC-signed customer zone must sign the delegation
CNAME; if the signature chain breaks, issuance fails — which
verify-by-issuance catches as `:failed` with copy that names DNSSEC as
the likely cause. Our `acme.fluxvale.app` target zone is
Cloudflare-DNSSEC-signed.

### 7. Routing and the wake-knock: #301 semantics survive the rename-keying

`EdgeRoutes` gains access-mode arms alongside its public two:

- `apply_access_serving` — per attached instance, per hostname row:
  IngressRoute `Host(<hostname>)` on entrypoint `access`, TLS from the
  domain's secret (or the default store for `fluxvale.app`), target the
  app Service, beacon middleware attached (idle clock works on the
  private path — the beacon is hostname-agnostic).
- `apply_access_wake` — same match, target the platform's
  `/internal/access/<gateway-id>/<instance-id>` path via the wake
  ExternalName pattern; **the path pair is the authorization, exactly as
  serve's asleep target encoded it**.
- `apply_access_none` — delete the access routes (detach, or gateway
  teardown).

The sleeping/waking flip is the same contract as #301/ADR-0039 §6 with
one substituted limb: `AccessWakeController` — the pairing gate, the
identical-404 miss posture, the no-redirect waking page, the status
table, the funded gate, the non-GET 503+Retry-After — is **unchanged
code**. What changes is who forwards to it (Traefik instead of serve's
proxy) and what the debounced flip writes:
`Edge.Activity.claim_access_flip/1` still debounces; the flip now
re-applies `EdgeRoutes` access arms (and still refreshes the serve config
for the ts.net fallback port — both limbs, one claim). The maybe-recheck
last-writer race guard carries over verbatim to the IngressRoute apply.

Because routing is now Host-keyed, the per-app **port** stops being the
product's routing identity on the custom-hostname arm (443 for
everything); `AccessRoute.route_key` stays the ts.net port for the
fallback arm. Hostnames route via `InstanceHostname` rows — the
provider-opaque seam ADR-0039 §2 promised is preserved (the access arms
are EdgeRoutes', not Tailscale's).

The app now **sees its real hostname** (Host header passes through the
tunnel untouched) — ADR-0038 §4's known limitation (private apps deriving
links from the ts.net host) is closed for the custom-hostname arm; the
deploy env's URL seeding (`instance_url_env`) may now set the hostname
for private instances **whose domain is claimed and live**, and app env
gains the hostname in host-allowlist catalogs (Django-class
`ALLOWED_HOSTS`) — slice detail, catalog-convention.

### 8. Exposure is a resolution question; the toggle is a compensated write

Formally, after this ADR:

- A hostname's **serving plane** is uniform: an IngressRoute on the
  public entrypoint, the access entrypoint, both, or neither.
- `public` means: public DNS resolves the hostname (Cloudflare wildcard
  for `fluxvale.app`; the customer's host CNAME for custom domains) and
  the public route exists. Tailnet devices *may* also resolve it — the
  resolver forwards to public recursion — so on-tailnet behaves like
  off-tailnet.
- `private` + attached means: the public route is absent (edge dark —
  ADR-0038, unchanged) and **the tailnet answer flips** to the gateway
  IP (one ConfigMap write). Resolution decides reachability; route
  presence decides serviceability.
- `private` + unattached: nothing (panel-only) — unchanged.

Toggle ordering (both directions) extends ADR-0038 §1's compensated
transaction with two new limbs, applied inside `set_exposure`'s existing
lock-and-compensate discipline:

- **public → private**: mint access routes for the instance's claimed
  hostnames (per current status: wake or serving arm) + flip the resolver
  answers, **then** the existing public deletes. Failure of the private
  limbs compensates back (no dark-for-tailnet window where the public
  route is already gone); failure of the public deletes rolls the row
  back public — the ADR-0038 arm, unchanged.
- **private → public**: existing public mints first, then un-flip the
  resolver answers + (per the one-step product decision from the smoke
  feedback) the detach stays the UX lane's behavior to compose.

The ADR-0039 §7 lock discipline is untouched (the row lock still
serializes toggle/sleep/deploy); the resolver ConfigMap and access-route
writes join the same critical sections, so no toggle leaves a
half-resolved hostname any more than it could leave a half-minted edge.

Attach/detach compose the same way: attach (private only, as today)
mints access routes + resolver answers; detach removes both and the
instance returns to panel-only.

### 9. Migration from ts.net-keyed serving

- The serve-config generator gains the tunnel limb as an additive change;
  existing `Web` per-app entries keep their shape (the in-flight
  concrete-domain + wake-path fix is the foundation this builds on —
  same file, sequenced behind it).
- Nothing moves for orgs that never claim: gateway, ports, ts.net
  addresses, wake — all byte-identical behavior.
- Claiming a domain is per-org, per-gateway, owner-triggered in settings
  (API token → route approval → split-DNS claim → resolver view), and
  hostnames begin answering as soon as the claim lands. The ts.net
  address remains displayed as fallback (the smoke-feedback item-5 link,
  kept honest: "works on your tailnet without any setup").
- Rollback is deleting the claim: resolver answers revert to forwarding
  (dark for private), the tunnel limb may stay (harmless; no route
  answers at the access edge once hostnames un-flip).

### 10. Multi-gateway, multi-tailnet, multi-cluster

- **One gateway per org** (ADR-0039 §8) still holds. Multiple orgs may
  share one tailnet (the owner's own case): each gateway gets its own
  resolver view; one split-DNS route per domain serves all of them;
  per-gateway views keep answers org-scoped.
- **A domain may be claimed on several tailnets** (personal tailnet +
  company tailnet, both with gateways for orgs the owner controls): each
  tailnet's claim is independent, each resolver answers with the IPs of
  that tailnet's reachable gateways. The registry row is org-scoped;
  claims are gateway-scoped.
- **Multi-cluster** (`Cluster` is the placement seam): the resolver and
  access edge are per-cluster; a gateway's tunnel and subnet route point
  at its own cluster's IPs. Cross-cluster hostname consistency (same
  hostname, instances on either cluster) resolves per-tailnet to the
  gateway the org attached — no new machinery; note for the [ADR-0006](00006-single-cluster-multi-region-ready.md)
  multi-cluster future.

### 11. Billing touchpoints

Per ADR-0039 §5's model, additive:

- **Gateway hourly accrual**: unchanged.
- **Per-domain line**: one flat monthly rate per `:verified` custom
  domain, billed hourly, `PerformSettle` discipline, ledger subject
  `"access-domain:<id>"` (the same additive nullable-column pattern — no
  new enum atom). Hostnames under `fluxvale.app`: free. Exposure, DNS,
  resolution: free, always.
- **The ladder must see it** (the §5 MUST-FIX pattern repeated):
  `ComputeRunway` adds active domains' rates; `SweepZeroBalance`'s ≤0 arm
  suspends domains (cert stays, resolution un-claims → honest dark)
  alongside instances and gateways.
- **Price — set by the owner in-session (2026-10-30)**:
  **$2.00/month per verified custom domain, billed hourly** — the same
  line shape as the gateway, one simple story: *access add-ons are $2
  each; `fluxvale.app` hostnames are free; exposure, DNS, and resolution
  are always free.* Built **parameterized** (seed/config value, no
  code-embedded price); the owner can override the number any time
  pre-ship with zero code change. Hostnames under `fluxvale.app`: free.
  Cost basis, for the record: one cert + renewal per domain, ~zero
  resolver/edge marginal cost, API calls ~none after claiming — the line
  buys support surface (DNS delegation help, DNSSEC cases, claim drift),
  like the gateway line before it.

### 12. Security posture (unsparing)

1. **The dns+routes token is the crown.** With it we can rewrite the
   customer's whole tailnet DNS (redirect every domain they resolve) and
   approve arbitrary subnet routes (expose other networks through
   tailnet nodes). Mitigations: minimal scopes, merge-only writes,
   idempotent claims, audit-logged, revocable by the customer
   unilaterally; residual risk remains — a FluxVale compromise during a
   claim window is a DNS hijack capability against that tailnet. This is
   the price of "same URL on the tailnet"; the weak form (item-5 link
   only) remains available to any customer who declines.
2. **We see resolution metadata.** Queries for claimed domains transit
   our resolver. Logging off, no retention; the fact stands: FluxVale
   can observe *which hostnames a tailnet asks for* while a domain is
   claimed. ADR-0039's "never sees the traffic" holds for bytes, not for
   names.
3. **CT ledger**: wildcards publish no hostnames. Per-hostname opt-out
   publishes every hostname (stated in copy). The ts.net fallback keeps
   publishing opaque `fv-` names (ADR-0039 §1, unchanged).
4. **The delegation CNAMEs are public** and name FluxVale zones
   (`_acme-challenge.apps.customer.com CNAME …acme.fluxvale.app`):
   anyone enumerating the customer's zone learns they use FluxVale.
   Zone-level only; hostnames stay hidden (wildcard). Unavoidable in the
   pattern; stated.
5. **Wildcard key blast radius**: one `*.apps.customer.com` key
   impersonates that subzone anywhere. `*.fluxvale.app` impersonates
   every default hostname — but that key already sits in the edge for
   public serving; the access entrypoint adds no new exposure class, and
   gateway pods never hold it.
6. **The subnet route must be exactly /32-of-one-Service.** Advertising
   a wider slice exposes real cluster Services to the tailnet. Fleet
   guard: reserved static IP, one Service, a naming/admission check on
   the access namespace; the spike's acceptance test enumerates what a
   tailnet client can reach through the route.
7. **Access-edge reachability is a NetworkPolicy invariant**: the
   `access` entrypoint port on Traefik accepts only gateway-pod
   selectors (rule-scoped ports+sources). Enforcement is ON (the fleet
   netpol lane, verified live) — but a policy regression here makes
   private apps publicly reachable, so the policy is pinned by test in
   the access-edge slice, not assumed.
8. **Tailnet membership is the boundary, still.** Every member device
   resolves and reaches every attached instance on their tailnet
   (ACLs are the customer's own control); same as B1, restated because
   "private" marketing must never imply per-user authz.
9. **Dangling delegations**: a customer who leaves without deleting the
   challenge CNAME leaves a takeover path for that hostname (anyone who
   can claim the target). Un-claim deletes our side; the panel's removal
   flow shows the CNAME to remove — the standard subdomain-takeover
   discipline.
10. **No new edge for probing**: the access edge answers only
    Host-matched routes with the same 404-nothing posture as the public
    edge; the wake pair gate (identical-404) is the #301 contract.

### Rejected alternatives

- **Serve keyed by custom hostnames with certs on the gateway** — the
  obvious reading of "strong": impossible today; serve's cert path is
  Tailscale-ACME-only (source-pinned above). Revisit if Tailscale ships
  custom-cert support (the tunnel design still wins on key custody).
- **ExtraRecords (tailnet-wide static DNS records) instead of a
  resolver** — no resolver infra and no subnet route, but every
  hostname/exposure change becomes a read-modify-write on the customer's
  whole tailnet DNS config (racy with their edits, chatty, per-toggle
  API use), no per-gateway view isolation on shared tailnets, and the
  token problem is identical. **Ruled at the gate as the accepted
  fallback** if the slice-0 UDP-through-netstack spike fails.
- **A privileged DNS pod on the tailnet** (kernel tun, second node):
  answers UDP natively but breaks the zero-privilege posture ADR-0039 §1
  established and needs Talos concessions; strictly worse than the
  subnet-route /32. **Ruled out at the gate — the zero-privilege posture
  is non-negotiable** (this is why ExtraRecords, not a privileged pod,
  is the spike fallback).
- **Public FluxVale resolver with private answers** — cannot
  authenticate member devices (NAT'd sources), so it answers existence
  to anyone; the exact leak the walls posture forbids.
- **Split-DNS to the gateway IP directly** — userspace nodes cannot
  answer inbound UDP; DNS-over-TCP only fails (forwarders don't fall
  back on timeout).
- **Weak edge redirect** (public subdomain → ts.net) — evaluated and
  dismissed in the smoke feedback: leaks existence, drops the session
  (cookie scope), worse than the tailnet link.

## References

- Source-pinned facts: `tailscale/tailscale` `ipn/ipnlocal/serve.go`
  (`getTLSServeCertForPort` → `GetCertPEM`; `TCPForward` on the same
  userspace dial path as `Proxy`); serve CLI docs (Jan 2026: no
  custom-cert flag); userspace UDP subnet forwarding shipped 2021
  (#2482, "less tested" caveat inherited by the spike).
- Repo seams this builds on: `access_providers/tailscale/serve_config.ex`
  (the generator this extends; the in-flight concrete-domain/wake-path
  fix lands first), `operations/edge_routes.ex` (the arms this adds to),
  `edge/activity.ex` (`claim_access_flip` reused), the AccessWake
  controller (unchanged), `clients/k8s/resources/ingress.ex` (`:host`,
  `:tls_secret_name` — "ported ready"), fleet wildcard/default-TLSStore
  (#116), thalmyra DNS-01 cluster-issuer overlays, the netpol-enforcement
  lane (walls verified live).
- ACME DNS-delegation pattern: the standard custom-domain mechanism
  (challenge CNAME into a platform zone); cert-manager's DNS-01 solver
  follows CNAMEs.
