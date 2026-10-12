# Data Deletion Statement (DRAFT)

**Status: DRAFT — advisor review and publication ride the M6 checkout
work** ([ADR-0029](adr/00029-payments-adapter-selfmor.md)). It backs the
zero-balance account destroy (#124): an org that empties its wallet,
serves its redemption window, and deletes its account must know exactly
what that deletes.

## What account deletion removes

- **Instances** — the namespace and everything in it (Deployment, PVC,
  Secret), torn down for good; the row goes with it. Customer application
  data is destroyed here, first and hardest.
- **Membership and organization** — the account and its access.
- **The wallet** — deleted with the org.

## What is retained, and why

- **Ledger entries** are financial records: they are what quarterly
  per-country tax summaries are queries over
  ([ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3 gate 3), and
  retention periods for financial records are a statutory matter. They
  carry no application data and no message content — the minimum needed
  to reconstruct the books.
- The draft stance: ledger retention outlives account deletion; the
  deletion statement says so plainly rather than implying total erasure.

## Open for advisor input (M6)

1. **Retention period** for financial records (PH BIR books/accounts
   retention is the anchor; advisor to confirm the binding number).
2. **Erasure vs pseudonymization** — whether retained entries must be
   disassociated from the deleted identity at deletion time, or their
   content already carries nothing personal.
3. **The refund interaction** — deleting mid-redemption-window (#124)
   with a pending refund.
