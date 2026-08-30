# ADR-00015: No auto-remediation — alert + prepared revert PR, human decides

**Status**: Accepted
**Date**: 2026-08-27

**Decision**: automation stops at *detection and preparation*. On smoke
failure, CI alerts (phone push, deep-linked), **opens the revert PR**
(`gh pr revert <n>`), comments on the offending PR, and posts a Grafana
annotation. A human merges (one tap from the phone) or writes the proper
counter-migration PR ([ADR-00014](00014-rollback-protocol.md) triage is genuinely human: flaky-test
attribution, the decision tree, data-loss calls).

**Rationale**: flaky browser tests cause false reverts (reverting good code is
a full pipeline cycle + eroded trust); detection-to-response is minutes at
solo scale (deploys happen at the keyboard); and remediation machinery is
meta-work — v1's core lesson is that meta-work must justify itself.

**Upgrade path to auto-merge** (only if: weeks of near-zero smoke flakiness
AND deploys happening while AFK): auto-merge the prepared revert **only when
the offending diff contains no files under `priv/repo/migrations`** —
migration-touching failures always escalate to a human.
