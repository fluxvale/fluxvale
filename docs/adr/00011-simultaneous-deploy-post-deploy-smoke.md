# ADR-00011: Simultaneous deploy + post-deploy smoke; gate-on-demand

**Status**: Accepted
**Date**: 2026-08-27

**Context**: v1 practice was one image deployed to staging and prod at once,
exposure gated by feature flags. A standing promotion gate (staging first,
prod after the smoke oracle approves) was analyzed: it reintroduces version
skew, making additive-only migrations *load-bearing* (expand/contract
discipline, contract releases) in exchange for protection that is mostly
already had — readiness probes self-contain boot-broken deploys (the new pod
never goes ready, old pods keep serving), and the dangerous class
(boots-fine-but-misbehaves) is caught by **post-deploy** smoke.

**Decision**:

- One image → Flux bumps staging **and** prod simultaneously.
- Post-deploy verification in CI: version-poll both envs' `/health` until it
  reports the new SHA (verifies DNS→Cloudflare→Traefik→pod; zero cluster
  credentials), then run Bruno on both, full Playwright on staging,
  read-only Playwright subset on prod. Merge-to-verified ≈ 12–20 min.
- Scheduled smoke (15–30 min cron) as synthetic monitoring for non-deploy
  breakage.
- **Gate-on-demand**: for scary migrations, pin prod in the fleet repo (one
  line), prove on staging, release. Opt-in, not standing.
- Real canary (Flagger + traffic split + metric analysis) deferred until
  traffic makes it statistically meaningful — at beta scale, 5% of traffic is
  nobody.

Full pipeline: [../deployment.md](../deployment.md).
