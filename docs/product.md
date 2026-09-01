# Product

## What FluxVale is

A **catalog-based PaaS for managed hosting of open-source applications**.
Users browse a curated catalog of apps, click install, get an instance
running on a subdomain
with HTTPS, and pay a flat monthly rate per instance from prepaid credits.

The defining shape: **browse → install → running, with zero configuration**.
This is not a developer platform (no YAML, no Dockerfiles, no cluster to
manage) — the catalog and the managed operation of it are the product.

The product surface is curation and zero-ops: we handle updates, TLS, uptime,
backups. The user just logs in and uses the app.

## Positioning

- **Zero-ops with a bill.** The customer never sees a server, a YAML file, or a
  Dockerfile — they see a catalog and a running app. (DIY self-hosting panels
  serve people who *want* to run their own infrastructure; that is a different
  customer.)
- **Differentiation test**: if the pitch can be approximated by "a self-hosting
  panel plus a payments page," it has failed. The moat is the managed side:
  curation, updates, backups, SFTP/file access, support, metering.
- **Agent-native.** A first-class JSON:API, a CLI, and an MCP server from
  day one — users operate their instances from terminal, scripts, or their
  AI agent. The web UI is one client among several, not the only door
  ([ADR-00019](adr/00019-machine-first-api-cli-mcp.md)).
- Landing page: "browse, click, running" — catalog-PaaS, not developer
  platform.

## Business model

- **Prepaid credits**: 1 credit = 1 US cent. Wallet per organization; balance is
  a live `sum` over an append-only ledger (never a stored column).
- **Flat-rate pricing** (ADR-00028): an instance's price is derived from its
  allocation (cpu/ram/storage) and shown as a simple **monthly rate**
  ("$X.XX/mo"), charged from credits pro-rata over elapsed time regardless
  of actual usage. Running = flat rate; stopped = storage-only flat fee
  ("pause it and it costs almost nothing"). No metered usage billing.
- **COGS anchor**: one Netcup RS 2000 G12 (8 dedicated EPYC cores, 16 GB ECC,
  512 GB NVMe) ≈ €21.61/mo actual billed price. Launch-gate sanity check:
  sum of flat prices at target density clears the box COGS with margin —
  see architecture.md's resource budget.
- Welcome credits on signup (anti-abuse TBD — open question #9).

## Non-goals (for the foreseeable future)

- Multi-cloud / hyperscaler support
- Enterprise features, SSO federation for the platform itself
- External developer API/CLI ecosystem (may come post-beta; the app is
  LiveView-first and no longer needs a public JSON:API to serve its own UI)
