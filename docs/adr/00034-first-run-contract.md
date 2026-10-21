# ADR-0034: First-run contract — a deployed app is usable on first open

**Status**: Accepted
**Date**: 2026-10-20

**Context**: the first production Forgejo deploy (#181, Oct 20 2026)
ran flawlessly and was unusable — registration closed, no admin
provisioned, no sign-up option behind the URL. The catalog's posture
was operator convention, not a guarantee: `INSTALL_LOCK=true` rode
`default_env_vars`, and `DISABLE_REGISTRATION` was a *deploy-time
configurable* — a form suggestion a user could flip to `true` at
create, bricking an instance nothing could ever sign in to (the
product has no admin-provisioning path, no pod exec). A deployed app
must be claimable by its owner within one click of opening the URL;
that property needs to be catalog data the deployer honors, not a
comment in a YAML file.

**Decision**:

1. `AppVersion.first_run` (nullable, typed by `FirstRunContract`)
   declares, per app, how first open works — one generalized field for
   every catalog app:

   - `pattern` — the taxonomy atom. One value exists today:
     `first_registered_user_admin` (registration open on first boot,
     first registrant becomes the admin). Adding a pattern = add the
     atom to the type's known set plus a row here; nothing else in the
     machinery is pattern-specific.
   - `env` — the guaranteed env posture. `DeriveFromAppVersion`
     applies it **above** every deploy-time layer
     (`contract > user > operator defaults > configurable schema
     defaults`); a user value naming a contract key is **rejected
     loudly**, never silently overridden.
   - `forbidden_env` — keys that must never ship (operator defaults,
     configurables, user env, or the version's `instance_url_env` —
     the deployer applies that one *over* the merged env, so it too is
     in the disjointness sweep): the knobs that would break first
     open. All key comparison is **case-insensitive** — consumers fold
     env names onto config settings without preserving case (Forgejo's
     `environment-to-ini` lowercases ini sections), so an exact-string
     lock would miss `FORGEJO__Service__…` spellings of a locked key.
   - `guidance` — owner-facing text rendered on the instance page:
     what to do on first open, what to close after setup.

2. **Forgejo ships `pattern: first_registered_user_admin` with
   `env: {INSTALL_LOCK: "true"}` and `forbidden_env:
   [DISABLE_REGISTRATION]`** — deliberately *not* pinning
   `DISABLE_REGISTRATION=false` (see Rejected). Registration-open on
   first boot rides Forgejo's upstream default (`DISABLE_REGISTRATION`
   defaults to false), held by the forbidden lock; the owner closes
   sign-up in Forgejo's own site administration after claiming.
   `INSTALL_LOCK` moved out of `default_env_vars` into the contract —
   one key, one home; `ValidateFirstRunEnv` keeps the contract's keys
   out of both env-var maps.

3. Evidence for the not-pinning call: Gitea/Forgejo
   `__section__KEY` env vars are applied to `app.ini` at **every
   container start** (Gitea docker docs: "applied each time the docker
   container starts" via `environment-to-ini`; Forgejo's docs note env
   can add/modify but never *remove* `app.ini` values). Pinning
   `false` would re-open registration at every restart after the
   owner closes it in-app — a silent security regression on a public
   URL. Not shipping the key keeps the in-app close durable, and the
   forbidden lock keeps every deploy-time layer from reintroducing it.

**Adding the next catalog app** (the generalized path): decide how it
becomes claimable on first open. If an existing pattern fits, declare
`pattern` + its `env`/`forbidden_env`/`guidance`. If a new pattern is
needed (e.g. generated admin credentials, an install wizard), add the
atom to `FirstRunContract`'s known set first — the deployer's
mechanism (`env` over everything, conflicts rejected) is already
pattern-agnostic. A version with no contract must simply be usable
out of the box.

**Rejected**:

- **Pin `DISABLE_REGISTRATION=false` in the shipped env** (the issue's
  literal pair `INSTALL_LOCK + DISABLE_REGISTRATION=false`) — env
  re-applies per boot (§3), so the documented "close registration
  after setup" would be silently undone at the next pod start.
  Registration-open is enforced as a *locked absence* instead.
- **Provision an initial admin via env secret** (an admin credential
  injected at boot) — needs secret refs on the blueprint (the
  catalog-read policy comment: a secret-carrying version revisits the
  public-read policy), per-app admin semantics, and a credential
  hand-off surface in the UI. Revisit trigger: a second app whose
  first-run genuinely needs generated credentials, or managed SSO
  ([ADR-0016](00016-deferred-triggers.md)'s PocketID deferral).
- **Keep the deploy-time "Disable public sign-up" toggle** (status
  quo) — deploy time is pre-admin by definition; flipping it creates
  an unreachable instance with no recovery path (the exact #181
  failure mode). The toggle is gone from `configurable_env_vars`.
- **Wizard-based first run** (`INSTALL_LOCK=false`) — multi-step, not
  one click, and the wizard is an unattended trap behind a managed
  product's proxy; skipped forever.
- **Post-deploy env editing to flip posture later** — no such feature
  exists (env is a create-time snapshot); designing one just to close
  registration is heavier than the in-app toggle Forgejo already
  provides. Env editing may arrive for its own reasons; the contract
  does not depend on it.

**Accepted risk**: with registration open, the first *registrant*
wins the admin seat. Mitigation is the haikunate subdomain (hard to
guess) plus guidance that says claim promptly; this is the standard
posture of every self-hosted forge's first boot.
