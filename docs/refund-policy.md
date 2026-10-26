# Refund Policy

**Status: PUBLISHED at `/policies/refund`** (in-app page, #140) — the
page goes live with the merge to `main`, and that merge is held for
the owner's advisor review (#140's gate): publishing and the advisor
pass are the same event, wording tweaks land before or right at it.
The customer-facing text of record is that page's template
(`apps/platform/lib/flux_vale_web/controllers/policy_html/refund.html.heex`)
— advisor edits are one cohesive change there. This doc is the
decision record.

## The stance (decided 2026-10-13, owner; PikaPods-shaped)

- **Credits are non-refundable.** No self-serve refund flow, no refund
  API integration in v1. The never-expiring balance IS the fairness
  argument: bought credit keeps full value indefinitely, and nothing is
  ever charged recurrently.
- **Chargebacks are handled structurally**, per
  [ADR-0029](adr/00029-payments-adapter-selfmor.md)'s accepted
  mitigation — small prepaid amounts, no recurring billing, access
  gating (an exhausted balance suspends instances rather than accruing
  debt; #124's zero-balance lifecycle). The policy states this plainly.
- **Goodwill credit is the only override path**: a manual exception a
  platform admin posts through the ledger's existing grant seam
  (`LedgerEntry :grant_goodwill` → `GrantCredits`, reason
  `:adjustment`) — offered as account credit, never money back, each
  case decided by a human. The policy names the exception without
  promising a refund channel.

This supersedes the M5 draft's "remaining credits are refundable"
stance (drafted with the ledger, #120, before the owner decided).

## Advisor review (pending)

The published wording is headed for the owner's advisor review — the
EU/UK distance-selling angle (14-day withdrawal expectations for
digital content) is the known nuance. Wording changes are a cheap
follow-up edit to the page template; the stance itself is settled.
The prepaid-credit VAT classification stays a separate open item
([open-questions.md](open-questions.md) #4, ADR-0029 Am. 3) — it
shifts *when* VAT attaches, not the refund stance.

[data-deletion.md](data-deletion.md) remains a draft until its
publication rides a lane of its own.
