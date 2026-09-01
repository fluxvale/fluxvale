# ADR-00018: Repo visibility — app repo public under FSL, fleet repo private

**Status**: Accepted (amended — see Amendment 1)
**Date**: 2026-08-27

**Decision**:

- `fluxvale/fluxvale` (this repo) is **open source under the Functional Source
  License, Version 1.1** (FSL-1.1), matching v1 — non-competing use permitted;
  competing use needs a commercial license; changes convert to Apache-2.0
  after the change date. `LICENSE.md` is ported from v1.
- `fluxvale/infrastructure` (the fleet repo) is **private**.

**Rationale**:

- **App repo public**: the product's transparency is the trust signal — and
  the marketing — for a hosting company. The public `docs/` (ADRs,
  architecture, deployment protocol) disclose *how we run things* honestly
  without publishing the operational map. FSL preserves the business model,
  as in v1.
- **Fleet repo private**: it is operational state plus a live map, not
  product source. Publishing it would grant zero-effort reconnaissance:
  exact chart/version pins (→ CVE targeting windows), UFW/SSH/fail2ban
  configuration, inventory and hostnames, deploy cadence from image-automation
  commits, backup windows, and restore/rotation runbooks. Credentials are not
  in git either way (fnox/Bitwarden references only) — a leak must never mean
  compromise, only cheaper attack. Obscurity is defense-in-depth, not a
  control.
- **Asymmetry**: private→public later is an auditable history-clean-and-publish
  exercise; public→private cannot unsee history.

**Consequences (the disclosure boundary)**:

Since this repo is public, its docs describe **architecture and decisions**
but never **operational specifics**: no public IPs, no chosen ports, no
inventory details, no version-pins-as-deployed. Those live in the private
fleet repo's runbooks. When v1 operational details are needed (e.g., the
nuremberg-01 setup), link to the v1 repo rather than restating them here.

**Cost note**: private repos and their CI (YAML lint) are free at this scale;
visibility is a pure security/tradeoff decision, not a budget one.

## Amendment 1 (2026-08-27)

Extended the disclosure boundary to **naming and strategy**: public docs never
name competitor services or rejected alternatives — the product is described
in our own words, and rejection rationale is written generically ("self-hosted
PaaS panels", "managed Kubernetes offerings", "EU cloud providers").
**Forward-looking business strategy (roadmap, future products, sequencing)
also stays out of public docs** — product docs describe what the product *is*;
strategy is published deliberately, if ever, not by repo leakage.
Names of our **chosen stack vendors** (Netcup, Cloudflare, CNPG, Traefik, …)
remain in ADRs — those are engineering facts, not positioning.
