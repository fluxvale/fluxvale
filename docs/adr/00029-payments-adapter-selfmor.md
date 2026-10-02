# ADR-0029: Payments — adapter architecture; self-MoR with Stripe (MoR products rejected)

**Status**: Accepted (amended — see Amendments 1–3)
**Date**: 2026-09-01

**Context**: v1 used Dodo Payments (checkout + Standard Webhooks). OQ #4
asked: keep or switch? Research settled it: Dodo, Paddle, Lemon Squeezy,
FastSpring — every "we handle taxes" product is a **merchant of record**, and
MoRs refuse or purge **hosting** as a category (stored customer content puts
DMCA/abuse liability on them). So FluxVale must be its own merchant of
record with a direct processor. Stripe is the first implementation.

**Decision**:

1. **Adapter architecture**: a `PaymentProvider` behaviour
   (`create_checkout/2`, `verify_webhook/2`, `fetch_payment/1`) with
   pluggable implementations (`Providers.Stripe` first; v1's Dodo code kept
   as the reference port). One active provider via config; per-provider
   webhook routes. Switching providers never touches the wallet.
2. **The ledger side was already provider-agnostic** — idempotency keys from
   payment IDs, append-only ledger, webhook → verify (constant-time,
   replay-window) → post once — all of that survives
   ([ADR-00028](00028-flat-rate-pricing.md)); only the signature scheme
   lives inside the adapter.
3. **Self-MoR obligations, accepted**: EU VAT (Stripe Tax; classify prepaid
   credits under voucher rules — launch-gate item, OQ #2), fraud/chargebacks
   (structurally mitigated: small prepaid amounts, no recurring billing,
   access gating), and a real refund policy.

**Resolves**: OQ #4. **Amends**: ADR-00028's Dodo reference (further amended: Xendit per Am. 1, HitPay per Am. 2).

## Amendment 1 (2026-09-01)

**Stripe is out — the entity is Philippine.** FLUXVALE INFORMATION SOLUTIONS
OPC (one-person corporation, Philippines) cannot open a Stripe account
(PH is not on Stripe's supported-countries list). **Xendit is the first
implementation** (established SEA infrastructure; hosted Invoice checkout
mapping 1:1 to `create_checkout`; callbacks verified via the
`x-callback-token` shared secret — constant-time compare, same discipline).
**Alternatives recorded**: HitPay (SME pricing), PayRex (PH-native,
API-first) — the adapter makes this a one-module swap.

**Self-MoR obligations, corrected**: the original EU-VAT/Stripe-Tax framing
assumed a EU entity — replaced by Philippine tax treatment of exported
digital services (zero-rating with documentation is the likely shape) plus
the prepaid-credits classification; still a launch-gate advisor item
(OQ #2). Currency: prices display in USD (credits = US cents); Xendit card
checkout in USD; settlement in PHP.

## Amendment 2 (2026-09-18)

**HitPay is the first implementation** — account approved (HitPay
approached us inbound; onboarded against a v1 demo), relationship
established. Xendit never shipped; it drops to recorded alternative.
Adapter architecture untouched: gateway migration stays a one-module
swap, and per-provider webhook routes + the provider-agnostic ledger
keep multiple concurrent gateways open if a concrete need ever appears
(maintainer requirement). Checkout/webhook mapping and HitPay's
signature scheme land in `Providers.HitPay` at M6 — same
constant-time verification discipline. USD display pricing carries
over; settlement currency re-confirmed at M6 (Am. 1's PHP settlement
was Xendit-specific).

## Amendment 3 (2026-10-02): Cross-border VAT concretized — registrations are launch gates

**Trigger**: a US micro-SaaS operator with zero UK/EU presence got an
HMRC "nudge" letter for uncollected UK VAT on B2C subscriptions — the
self-MoR exposure this ADR accepted, showing up on someone else's
doorstep. Research (2026-10-02) produced the map; the maintainer set
the gates.

**The rule**: B2C digital services are taxed where the *customer* is —
entity, bank, staff are irrelevant. B2B sales to VAT-registered
customers are reverse-charge (customer self-accounts) — no registration
duty. Our zero-ops audience skews consumer → day-one exposure in every
market we charge.

- **UK — £0 threshold** for non-established sellers (post-Brexit):
  register as a NETP (HMRC VAT1A), 20% on consumer sales, quarterly
  returns.
- **EU — €0 threshold** for non-EU sellers, nominally per member
  state; the **non-Union OSS** collapses it — one registration
  (Ireland presumed) + one quarterly return covers all 27, each
  customer's country rate.
- **Rest of world — threshold-gated**: TH THB 1.8M, AU A$75k, CA
  C$30k, JP ¥10M, NO NOK 50k, US per-state economic nexus (~$100k;
  SaaS taxability varies). Watchlist; register on approach.
  Revenue-by-billing-country (gate 3's persisted fields) is the whole
  monitoring mechanism.
- **PH (Am. 1's item, stands)**: exported services zero-rated VAT with
  documentation — the checkout location evidence doubles as BIR proof.

**Gates — blockers before the first real charge** (decided 2026-10-02;
M6's test-mode checkout is exempt, production charges are not):

1. UK NETP + EU OSS registrations live.
2. Checkout tax layer (HitPay has no Stripe-Tax equivalent — we own
   it): billing country, customer type, VAT number (B2B →
   reverse-charge), **two non-contradictory location proofs** (billing
   address + IP — the OSS evidence requirement), consumer prices
   carrying the customer's country rate.
3. Quarterly per-country tax summaries emittable from the ledger —
   rows must persist gate 2's billing country and applied rate so a
   return is a query, not a reconstruction (the M5 schema inherits
   this commitment).

**Still advisor items (OQ #4)**: OSS member state, prepaid-credit
voucher classification (single-purpose = VAT at purchase,
multi-purpose = at redemption — shifts *when*, not *whether*), PH
zero-rating documentation, DIY vs agent filings (Taxually/Marosa/Fonoa
class, ~€100–300/jurisdiction/yr).
