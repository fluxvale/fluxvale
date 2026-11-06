# FluxVale platform

The Phoenix 1.8 + Ash application (`:flux_vale`) — the product's single
OTP release. One app in this directory, no umbrella.

Start here:

- [AGENTS.md](AGENTS.md) — this app's conventions (they win over generic
  Phoenix guidance), on top of the [repo root](../../AGENTS.md).
- [docs/](../../docs/README.md) — what's decided and why. Accepted ADRs
  are settled law.
- [Root README](../../README.md) — local development, both the plain
  path (`mix setup`, any PostgreSQL 18+) and the production-parity
  stack ([ADR-0020](../../docs/adr/00020-local-dev-parity.md)).

The gate every PR passes, from this directory:

```sh
mix ci    # format, unused deps, warnings, gettext, blog lint,
          # ash codegen drift, credo --strict, dialyzer, coveralls
```

Concurrent local suites need their own DB (#241):

```sh
MIX_TEST_PARTITION=<lane> mix test
```
