# ADR-00008: Platform app runs in-cluster

**Status**: Accepted
**Date**: 2026-08-27

**Context**: host placement (systemd service, app as *client* of the cluster)
was debated at length. Its case — flat dependency chain, simpler DR, the
platform surviving cluster incidents, staging as one more systemd unit — was
strongest against the **v1 pile** (CNPG circularity, operator zoo, pricier
staging), all of which is cut anyway. What remained was low-frequency
survivability scenarios weighed against: one paradigm, rolling deploys +
probes for the app itself, `dependsOn`-ordered rollout, and six months of v1
operating in-cluster without placement-related pain. Lived experience beat
the theorycrafting.

**Decision**: the app is a Deployment in `fluxvale-staging` /
`fluxvale-production`, rolled out by Flux. Traefik fronts it; migrations run
in init containers.

**Safety conditions**: [ADR-00009](00009-single-cnpg-cluster.md)'s single-cluster guardrails (per-tenant roles, quotas, WAL-G),
[ADR-00014](00014-rollback-protocol.md)'s rollback protocol, and everything-on-the-cluster-lives-in-git (one exception:
   the BWS operator's bootstrap token Secrets — values, created out-of-band,
   ADR-0021).
An out-of-band admin path (Cloudflare Tunnel or direct port, bypassing the
cluster edge) is worth keeping as an emergency window.

**Note**: reversibility is asymmetric (host→cluster later is an afternoon;
cluster→host is a project with a CNPG extraction in the middle) — accepted.
Revisit trigger: building HA Postgres / node #2 (see [ADR-00016](00016-deferred-triggers.md)).
