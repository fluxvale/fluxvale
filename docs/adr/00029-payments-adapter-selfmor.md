# ADR-0029: Payments — adapter architecture; self-MoR with Stripe (MoR products rejected)

**Status**: Accepted (amended — see Amendment 1)
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

**Resolves**: OQ #4. **Amends**: ADR-00028's Dodo reference (further amended: Xendit per Am. 1).

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
