# FluxVale v2 — Project Documentation

The **FluxVale v2** repo: <https://github.com/fluxvale/fluxvale>
(kicked off 2026-08-27). What was decided, **why**, what was rejected,
what's still open. v1: <https://github.com/fluxvale/fluxvale_old>
(read-only; carry-over map in [v1-salvage.md](v1-salvage.md)).

## Document map

| Doc | Contents |
|---|---|
| [product.md](product.md) | What FluxVale is, positioning, pricing model |
| [architecture.md](architecture.md) | Settled stack, topology, environments, growth model, repo shape |
| [deployment.md](deployment.md) | Deploy pipeline, smoke tests, migration rules, rollback protocol |
| [observability.md](observability.md) | Monitoring stack, instrumentation plan, alert set |
| [pricing-calibration.md](pricing-calibration.md) | The ADR-0028 launch-gate check: price table, market anchor, density math |
| [pricing-recalibration-2026-10.md](pricing-recalibration-2026-10.md) | Proposed recalibration for NetCup renewal costs (#200) — options + recommendation, awaiting owner decision |
| [design-system.md](design-system.md) | The amber design system (#178): tokens, components, storybook, wave-2 plan |
| [adr/](adr/) | One decision per file, with rationale and rejected alternatives — index in [adr/README.md](adr/README.md) |
| [refund-policy.md](refund-policy.md) · [data-deletion.md](data-deletion.md) | Customer-facing policy drafts — advisor review + publication ride M6 checkout ([ADR-0029](adr/00029-payments-adapter-selfmor.md)) |
| [open-questions.md](open-questions.md) | Everything deliberately **not** decided yet |
| [v1-salvage.md](v1-salvage.md) | What to carry over from v1 (and what to leave behind) |

## Working with these docs (humans and agents)

- **Read [adr/](adr/) before proposing changes** to infrastructure,
  deployment, or architecture. Accepted ADRs are settled — don't
  re-litigate in a work session; new evidence earns an **amendment**
  (append `## Amendment N` with date and rationale — conventions in
  [adr/README.md](adr/README.md)).
- Anything not decided lives in
  [open-questions.md](open-questions.md) — surface it, don't invent an
  answer.
- Docs describe the *target* architecture during scaffolding; update
  them in the same PR as the change.
- Process weight is a v1 scar: keep workflow machinery proportional
  to shipped product.
