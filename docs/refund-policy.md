# Refund Policy (DRAFT)

**Status: DRAFT — advisor review and publication ride the M6 checkout
work** ([ADR-0029](adr/00029-payments-adapter-selfmor.md); drafts landed
with the ledger, #120). Nothing here binds until published.

## What is refundable

- **Remaining (unconsumed) credits are refundable** — prepaid credits
  bought and not yet spent go back to the payment method on request.
- **Consumed hosting is non-refundable** — a flat-rate month already
  accrued against ([ADR-0028](00028-flat-rate-pricing.md)) paid for real
  capacity held; it does not unwind.
- **Welcome credits are not refundable** — they were never purchased.

## How refunds work (the ledger contract)

A refund is a **reversal entry** against the purchase entry it offsets
(`reverses_id`) — ledger rows are never mutated or deleted. The refund
moves money out through the payment provider; the wallet only ever sees
the compensating entry. One reversal per entry, enforced at the database.

## Open for advisor input (M6)

1. **Refund window** — a time limit on remaining-credit refunds (v1 had
   none; the zero-balance lifecycle, #124, interacts with this).
2. **Provider rails** — HitPay refund mechanics, partial-refund support,
   and who eats the processing fee.
3. **Prepaid-credit classification** — voucher-rule treatment shifts
   *when* VAT attaches (purchase vs redemption), not whether (OQ #4).
4. **Abuse posture** — chargeback mitigation is structural (small prepaid
   amounts, no recurring billing, access gating) but the written stance
   needs advisor review.
