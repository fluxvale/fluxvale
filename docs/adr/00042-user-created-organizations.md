# ADR-0042: User-created organizations

**Status**: Accepted (the lane shipped slice-by-slice — #420, #430,
#437, #441, #460, #414, #452, plus rider #456; this ADR is the
decision's record)
**Date**: 2026-11-05

## Context

The platform was already org-shaped underneath: every user gets a
hidden personal org at signup, and instances, wallets, and gateways
all belong to organizations. What was missing was the visible
organization — letting a person create a team org, letting others join
one, and letting deploys and top-ups happen in an org's context
instead of always the personal one. Two latent breakages forced
decisions: "the personal org" was a derived notion
(earliest-created-owned-org) that user-created orgs would corrupt, and
the org billing page could not top up, so enable-actions on org pages
billed the actor's personal wallet. The owner settled the six open
rulings on Nov 4 (#408); the lane shipped them across eight slices and
riders.

## Decision

### Creation

Any signed-in user below a soft cap of 10 owned orgs creates a team
org through `CreateOrganization`'s `create_with_owner` action (#430).
One transaction creates the org and the creator's single `owner`
membership — the membership create policy stays closed to every other
path; invites are the only way into an existing org. A created org
gets **no welcome credits**: the $3 grant is the per-user signup
entitlement, and the org is the abuse boundary (#122) — per-org free
credits would be a free-money faucet (create, spend, repeat).

Reserved slugs bind **creation only**; the rename flow keeps its
no-reservations behavior — the documented asymmetry (#430). Revisit
when org slugs become shareable — the invite flow is the surface that
would share them, and they are not shareable today.

The creation page is **de-socialized** — the owner's Nov 5 ruling
after dogfooding (#456): one name input, the `/organizations/<slug>`
address derives live on every keystroke, no manual slug field in v1,
no advanced affordance. A derived address that fails a slug rule reads
as one plain line (try a different name); no silent suffixing.

### The personal-org marker

`personal_owner_id` on organizations is the explicit fact behind "the
personal org" (#420) — unique when set, null marks team orgs. It
replaces the earliest-owned derivation, which could not survive
user-created orgs (a destroyed personal org plus a later created org
would hijack the personal-account redirects). The backfill stamped
every existing user's derived org; JIT provisioning sets the column,
`create_with_owner` leaves it null.

### Billing attribution — Option A

Every org owns its wallet and tops up itself: the top-up wizard takes
an org context, VAT evidence unchanged (#414). No billing-engine
change — the one-wallet-per-org invariant already ran the ledger,
accrual, sweep, runway, and paywall checks. `has-paid` stays per-org:
an org must itself pay once to unlock private access and backups.
Created orgs get a wallet lazily at zero (`ensure_wallet`) and no
welcome grant.

### Membership — the Stripe model

Per-org access grants: a user belongs to many orgs, each grant row
carrying a per-org role (#441, #460). v1 ships `owner` and `member`
via invites — hashed token links, accept fenced to the matching
verified primary email, one open invite per org+email — and the
lifecycle: promote/demote, owner removal, self-leave, and the
last-owner guard under an org-row lock. Finer roles
(admin/developer/viewer) are a later value-add **on the same grant
rows** — the role enum is the axis, no schema redesign.

Instance transfers into orgs are **deferred** — the owner's rationale:
pre-launch there is nothing to transfer. Revisit at the first customer
ask.

### Org context

Deploys and gateways follow the named-org context (#452): the deploy
wizard gains an org picker, and the change modules stop force-pinning
the personal org when an org is named. The member fence is the
Instance create policy's own
(`relates_to_actor_via([:organization, :members])`), and the wallet
gates read the same resolution — enabling private access on an org
page bills the page org's wallet, closing the documented wrong-wallet
divergence.

### Deferred

Agent-facing org tools — an API scope plus
`create_organization`/`list_members` MCP tools — are deferred to a
follow-up; the seam is ready when agents need it. The broader social
layer (public org surfaces) is **parked post-launch**: the feedback
board is the experiment, and it decides.

## The six owner rulings (Nov 4, #408)

1. **Billing = Option A** — the org owns its wallet with its own
   top-up.
2. **Transfers deferred** — nothing to transfer pre-launch; revisit at
   the first customer ask.
3. **Invites with an accept flow** — no direct add by email.
4. **The `personal_owner_id` marker** — nullable uuid, unique index,
   single-UPDATE backfill, null = team org.
5. **Membership = the Stripe model** — per-org roles on the same
   grant rows; owner+member in v1; finer roles a later value-add on
   the same rows; `whoami` carries the role per org; agent-facing org
   tools stay deferred.
6. **Reserved slugs + the 10-org soft cap** — org slugs are path
   identities; users never define subdomains (instance hostnames are
   platform-assigned, custom domains the paid verified add-on).

## Rejected alternatives

- **Creator-funded billing (Option B)** — the org spends the
  creator's personal wallet. Inverts the abuse boundary (#122: the org
  is the entitlement boundary, the bill lands on a person) and forks
  every wallet resolution — accrual, sweep, runway, paywall, MCP
  `get_wallet` would all need a redirect rule.
- **Hybrid billing (Option C)** — org wallet plus auto-sweep from the
  creator: two balances to explain, a sweep job to build, a refund
  story spanning wallets.
- **Direct add by email** — immediate-add notifies any address and
  leaks the org's existence; invite rows put consent in the invitee's
  hands.
- **A third role tier now** — every gate branches owner-vs-member
  today; an admin tier forks every policy for little beta value (the
  enum axis keeps it additive later).
- **Manual slug entry on the creation page** — the dogfooded
  `phx-change` serialization bug (an untouched input silently overrides
  the server's derivation) dies by construction when the field does
  not exist (#456).

**Resolves**: #408 (the umbrella; its six Nov 4 rulings are restated
above). The deferred agent tools and the parked social layer carry
their triggers in [open-questions.md](../open-questions.md).
