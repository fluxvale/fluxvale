# Plan: the company dogfood — Forgejo + Umami on FluxVale (#690)

Status: **APPROVED (2026-11-13).** Phases S1–S7 fan out as sub-issues
of the umbrella. Umbrella: [#690](https://github.com/fluxvale/fluxvale/issues/690).
Evidence base: this repo's code on main at approval (0b05dfc2), the
catalog seeds,
[ADR-0040](../adr/00040-strong-private-access-and-custom-domains.md),
[#597](https://github.com/fluxvale/fluxvale/issues/597)'s shipped slices
([597-pocketid-sso.md](597-pocketid-sso.md)), and the external
verifications named inline (Umami docs, ash_authentication v4.15.1).

## 1. The initiative in one paragraph

The company runs on its own product: a Forgejo instance for company git,
an Umami instance for fluxvale.com analytics, both deployed through the
platform into the company's own org, serving at git.fluxvale.com and
analytics.fluxvale.com — and SSO across them evaluated honestly rather
than assumed. The phasing puts usable instances first (no product
code), SSO second (manual wiring, no product code), and custom domains
third (one product slice the feature was always going to need). Every
gap hit on the way is filed as candidate feedback — that is half the
deliverable.

## 2. Verified grounds (what main actually has)

- **Custom domains, registration + verification + private serving
  arms: built.** `AccessDomain` register (member API + the Terraform
  `fluxvale_custom_domain` resource — the provider now lives in its
  own repo, [ADR-0051](../adr/00051-tfprovider-repo-extraction.md)),
  verify-by-issuance (wildcard cert
  via DNS-01 through `_acme-challenge` delegation, ~15 min pass),
  Host-keyed IngressRoutes on the `access` entrypoint, per-gateway
  resolver views, split-DNS claiming — all on main per
  [ADR-0040](../adr/00040-strong-private-access-and-custom-domains.md)
  Am.1 and the operations under
  `contexts/infrastructure/operations/`.
- **The missing piece is the hostname mint.** `InstanceHostname` rows
  are system-minted for the platform domain only
  (`MintDefaultHostname` → `<slug>.fluxvale.app`); the resource's own
  doc says a custom label under a custom domain's wildcard is
  "later". No member or admin path mints `git.fluxvale.com` today. The
  consuming arms (edge routes, resolver, the DAV sibling) already read
  these rows — the mint is the one slice between a verified domain and
  a serving custom hostname.
- **Public custom-domain serving: not built.** The public serving arm
  routes only `instances_base_domain` hostnames; a public CNAME for a
  custom domain has nothing to land on (ADR-0040 §2 ruled
  private-first; public serving is the named follow-up).
- **PocketID SSO machinery: slices 1–6 merged** (#683 supplied the
  guide and turned the flag on). Recipes are env-var based,
  Vaultwarden/Vikunja-only in the automatic path. The catalog already
  pins Forgejo's callback path (`/user/oauth2/PocketID/callback`, from
  #511's research, which verified Forgejo consumes OIDC via admin-UI
  auth sources — DB-stored, no env surface).
- **Umami self-hosted has no SSO, full stop.** Verified against the
  complete v3 docs tree and the entire environment-variable reference
  (current through v3.5.0): auth surface is the default admin
  account, passwords, and optional 2FA. SSO is an Umami Cloud
  feature. No OIDC client exists to wire to anything.
- **The platform's own auth is a consumer, not a provider.**
  ash_authentication v4.15.1 ships client-side strategies only
  (OAuth2/OIDC consumption, magic link, API keys, tokens); there is no
  provider/OIDC-server path in the package or the Ash ecosystem.
- **The prod Umami step from #576 is still open** — the instance and
  the `UMAMI_SCRIPT_URL`/`UMAMI_WEBSITE_ID` site env. This plan
  completes it rather than duplicating it.

## 3. The three SSO shapes, honestly

| | (a) FluxVale auth becomes an OIDC provider | (b) PocketID as the IdP | (c) No SSO for v1 |
|---|---|---|---|
| What it takes | Boruta (separate Elixir OIDC server lib) or hand-rolled authorize/token/JWKS/discovery + client registry + key rotation + consent UX, beside the passwordless core | Zero product code: catalog PocketID 2.19.2 + manual wiring (PocketID client + Forgejo auth source) | Zero |
| Effort | 4–6 slices, a lane-week-plus, security-heavy review arc, a second auth-critical surface to maintain forever | ~30–60 min operator steps; optional small docs slice | Zero |
| Forgejo covered | Yes (it's an OIDC client) | Yes — verified by #511, callback path already in catalog | No |
| Umami covered | No — Umami has no OIDC client regardless of IdP | No — same | No |
| Strategic fit | Duplicates the IdP our own catalog already ships; #511 explicitly parked "PocketID for the platform's own login" as deliberately-waiting — building a second IdP inverts that restraint | Exactly the intended PocketID role ("other apps use this instance as their sign-in provider") | — |
| Verdict | **Reject** for this initiative; revisit only if "sign in with FluxVale" becomes a customer promise | **Recommended, phase 2** | The de-facto phase 1 state; not the strategy |

The Umami row is the honest ceiling: no SSO shape reaches it, because
the self-hosted product has no OIDC client. Umami keeps local accounts
(admin + named users, 2FA available) — stated plainly, not papered
over.

## 4. Custom domains end to end (phase 3's path, walked)

For `git.fluxvale.com`, private-first per ADR-0040 (company-internal =
tailnet is the boundary; no public record needs to exist at all):

1. **Register** `fluxvale.com` as the org's AccessDomain (member API
   or Terraform) → `:pending`. Money gate: see §5.
2. **Delegation records, self-served**: we hold the zone on Cloudflare,
   so we create the challenge delegation ourselves —
   `_acme-challenge.fluxvale.com CNAME <token>.acme.fluxvale.app`.
   Private-only needs **no host CNAME** (the maximum-invisibility
   shape, ADR-0040 §6). One fleet-repo config check: the DNS-01
   solver's Cloudflare token must cover the zone.
3. **Verify**: the ~15-min pass issues the wildcard `*.fluxvale.com`
   through cert-manager → `:verified`. No certificate, no verified
   domain — the honest gate, and it renews forever after.
4. **Gateway + claim**: the org's gateway on the company tailnet
   (one-time four-scope Tailscale token, ADR-0040 Am.3's
   mint-not-paste intake) claims the domain — split-DNS route +
   resolver subnet route, one-time per tailnet.
5. **Mint the hostnames — the product slice**: `git` (and later
   `analytics`) under the verified domain, attached to their
   instances. API + instance-page surface; the serving arms consume
   the rows as-is.
6. **Serve**: `Host(git.fluxvale.com)` answers on the `access`
   entrypoint with the wildcard cert; the resolver answers the
   gateway's tailnet IP; off-tailnet the name resolves to nothing.

`analytics.fluxvale.com` is different: the tracking script is loaded by
public visitors' browsers, so it needs **public** custom-domain
serving — not built (§2). Until that ships as product, Umami stays on
its default public `<slug>.fluxvale.app` hostname, which works today
and is what `UMAMI_SCRIPT_URL` will point at in phase 1 anyway.

## 5. The money story

The gate (both `AccessDomain :register` and gateway `:create`): the org
must be **paid once** — a completed real top-up of $1+ ever (welcome
credit does not qualify; the check reads the ledger's `:purchase`
reason) **or** the operator's `paywall_waived` flag from /admin — and
**funded now** (balance > 0; the $3 welcome credit qualifies).

The waiver is a legitimate, built path (designated orgs). But it funds
nothing: instances accrue hourly, and a drained wallet suspends the
stack (the zero-balance sweeper). The dogfood costs real metered money
either way — roughly, at catalog sizes: Forgejo small + 10 GB ≈ $7.00,
Umami (bundled; small for headroom, micro boots near the 512 MB line)
≈ $6.60–7.70, PocketID micro + 2 GB ≈ $3.40, gateway ≈ $2.00 —
**≈ $16–19/month total**.

Recommendation: **one real top-up, $20 suggested** ($5 is the guide's
own minimum bar). It completes the payments dogfood end to end
(checkout → webhook → wallet credit → ledger), lands in FluxVale's own
Polar account so the net cost is the processor fee, and covers ~5
weeks past the welcome credit. The waiver is the fallback if the owner
wants the payment path isolated from this initiative. His call, stated
plainly: **real money now (how much), or waiver first and top up when
the stack sticks.**

## 6. Phased slices

Phase order is deliberate: instances deliver value with zero product
code; SSO is cheaper than domains (domains need the mint slice);
domains last so the pretty names land once everything else is proven.

- **S1 — org + wallet (operator).** Company org exists; wallet
  decision per §5 executed (top-up or waiver). *Done when:* the
  wallet shows a `:purchase` credit (or the waiver flag) and balance
  > 0.
- **S2 — the stack, live (operator).** Gateway enabled on the company
  tailnet (token intake); PocketID instance — public, always-on flag,
  `ENCRYPTION_KEY` saved, admin claimed, first passkey (its catalog
  copy pins the load-bearing posture); Forgejo instance — private,
  attached, first registrant = admin, registration closed after;
  Umami instance — bundled row, public, default admin rotated.
  *Done when:* Forgejo answers on the tailnet at its default
  hostname, Umami's `/api/heartbeat` returns `{"ok":true}`, and all
  three show Running in the console.
- **S3 — analytics real (operator).** `UMAMI_SCRIPT_URL` +
  `UMAMI_WEBSITE_ID` set on prod (after any pre-launch wipe), website
  added in Umami. *Done when:* real fluxvale.com visits appear in the
  dashboard — closes #576's leftover operator step.
- **S4 — SSO, manual wiring (operator).** PocketID user(s); PocketID
  OIDC client for Forgejo (callback
  `https://<forgejo-host>/user/oauth2/PocketID/callback`); Forgejo
  admin → Authentication Sources → OAuth2 against PocketID's
  discovery URL. *Done when:* a passkey sign-in lands in Forgejo as a
  real user and the local admin path still works (the degradation
  path #511 verified).
- **S5 — the cookbook page (optional small lane).** Public docs
  guide: SSO between your instances, PocketID + Forgejo end to end,
  honest always-on/second-passkey copy — #511's v1 proposal shipped
  as the doc it always wanted to be. *Done when:* the guide renders
  at /docs with the wiring verified against the live company stack.
- **S6 — custom-hostname mint (product lane; the umbrella's one
  required build).** Member API + instance-page surface + e2e; the
  arms consume rows unchanged. Rides §4 steps 1–4 as its
  preconditions. *Done when:* `git.fluxvale.com` answers on the
  tailnet with a valid `*.fluxvale.com` cert and is dark
  off-tailnet; the mint is exercised by e2e.
- **S7 — analytics.fluxvale.com (decision-gated).** Public
  custom-domain serving (host CNAME + public-entrypoint arm + TLS) —
  a medium slice — or Umami keeps its default hostname (zero work).
  *Done when:* either the public name serves the tracker, or the
  decision to defer is recorded here.

Sequencing note: SSO before custom domains means the PocketID client
and Forgejo's `ROOT_URL` reference the default hostname; adopting
`git.fluxvale.com` later re-wires both ends (~10 min, a config change
each side). Acceptable at company scale; noted so it surprises no one.

## 7. Dogfood findings → candidate issues

Each firms up into its own issue under the umbrella as it's worked:

1. **Custom-hostname mint** — S6 promoted to its own issue on go.
2. **Public custom-domain serving** — S7's build option.
3. **SSO recipes for DB-configured apps** — the recipe system is
   env-only; Forgejo-class apps (OIDC config in their own database)
   can't join the #597 wizard. Needs research: does Forgejo expose an
   admin API for auth sources? (Unverified.)
4. **Umami's SSO stance** — catalog copy should not imply SSO is
   reachable; state it as a Cloud-feature boundary.
5. **The custom-domains guide understates the present** — "the
   remaining half … still being built" reads as if nothing serves;
   the serving arms exist and only the mint is missing. Refresh with
   S6.
6. **Instance URL stability** — the ROOT_URL/callback re-wire dance
   when a custom hostname lands on a live instance; maybe a future
   re-home op.

## 8. Decisions needing the owner

- **D1 — money:** real top-up now (amount; $20 suggested) vs waiver
  first, top up later (§5).
- **D2 — phase order:** as presented (instances → SSO → domains), or
  domains pulled ahead because the names matter more than the login.
- **D3 — Forgejo posture:** private-on-tailnet from day one
  (recommended; the company boundary is the tailnet) vs public on the
  default hostname until domains land.
- **D4 — analytics.fluxvale.com:** build public custom-domain serving
  now (S7 build) or default hostname for now (recommended until the
  public arm ships as product).
- **D5 — the cookbook page:** S5 now or later.

## 9. Rejected alternatives

- **(a) The platform as its own IdP** — §3: real feature build,
  security-heavy, duplicates the catalog's PocketID; #511's
  deliberate-waiting stance stands.
- **Forward-auth for everything** — parked by #511 already; nothing
  here revives it.
- **Umami Cloud for analytics** — stops dogfooding the product this
  initiative exists to dogfood.
- **Public-first custom domains** — ADR-0040 ruled private-first;
  this plan sequences inside that ruling, it does not re-litigate.
