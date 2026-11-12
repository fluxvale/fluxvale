# ADR-0053: Secret env values — Terraform carries a locked box, never the secret

**Status**: Accepted for design; implementation deferred until T1–T3 (owner go Nov 12, 2026, #731 — the plan is
[plans/731-terraform-integrations.md](../plans/731-terraform-integrations.md))
**Date**: 2026-11-12

**Context**: Terraform is a first-class deploy surface, and app
integrations are env-var-shaped. A database URL, an API key, a shared
queue password — all are values one app must hand another. Today the
provider's `env_vars` is `sensitive`, which only means Terraform
redacts it in human output; the plaintext still lands in the state
file, the plan file, and any CI artifact that keeps them. State
backends are often a shared bucket, and a `.tfvars` in git is common.
"Sensitive" is a display setting, not a security boundary.

This ADR decides how a user-supplied secret reaches an app's env
without the plaintext entering Terraform state, plan files, git, or
the platform database. It is design-first: the build follows the
owner's go (plan slice T4-S2/T4-S3).

## What we are protecting, and from whom

| Surface | Today | With this decision |
|---|---|---|
| Terraform state | plaintext JSON in the backend | ciphertext only, inert without the platform key |
| Plan file / `plan -json` | plaintext inside the artifact | ciphertext only |
| CI logs | whatever the pipeline prints | plaintext stays in the CI secret store; only the marker is ever printed |
| Git (`*.tfvars`, HCL) | plaintext if committed | ciphertext, safe to commit |
| Platform Postgres | plaintext in `instances.env_vars` | ciphertext; a database backup no longer leaks these values |
| K8s etcd (the `app-env` Secret) | plaintext | **unchanged — out of scope** (tracked separately) |
| Runtime env | plaintext | **unchanged — necessarily** |

The adversary this defeats: someone who reads the state bucket, a
plan artifact, the repo, or a database backup. It does **not** defend
against a compromised platform process, which already writes every
runtime Secret — that is the trust boundary, stated plainly.

## Decision

1. **Encrypted values, decrypted by the platform at deploy.** A user
   encrypts a value with the CLI and puts the marker in `env_vars`:
   `enc:v1:<kid>:<payload>`. The platform stores the marker in the
   row, opens it only when composing the app's `app-env` Secret, and
   never echoes or logs the plaintext. The marker is opaque to
   Terraform: no provider attribute changes, no Terraform version
   floor, no state schema change.

2. **One platform keypair, ciphertext bound to its org and variable.**
   X25519 keypair per environment (prod, staging). The private half
   lives only in the platform's config, sourced from 1Password
   ([ADR-0021](00021-secrets-bws-operator.md) Am. 3). The CLI fetches
   the public half from the API; it never sees the private key.
   Each ciphertext is sealed with the AEAD's associated data set to
   `org_id || 0x00 || env_key`, so a marker from org A cannot be
   opened for org B, and a marker for `API_KEY` cannot be moved to
   `DATABASE_URL`.

   **Why one key, not per-org keys.** Per-org keys look safer, but
   every key would live in the same vault and be used by the same
   process; a compromise of the platform's key material decrypts
   every org either way, and the live K8s Secrets are readable by
   that same process. Per-org keys add a key table, generation,
   sealing, and rotation work without narrowing who can decrypt.
   Per-org (or per-customer) custody is the **BYOK** model — a
   different product decision, with its own ADR and trigger.

3. **The crypto is boring and pinned.** X25519 ephemeral ECDH →
   HKDF-SHA256 (`salt` = ephemeral public key, `info` =
   `"fluxvale env secret v1"`) → AES-256-GCM. The payload is
   `ephemeral_pub(32) || nonce(12) || ciphertext||tag`, base64url
   without padding. The `kid` is the first 4 bytes of
   SHA-256(public key), hex. `enc:v1:raw:<b64>` escapes a literal
   value that itself starts with `enc:v1:`. A marker that fails to
   open is a hard error — never a silent plaintext passthrough.
   A shared test vector (keypair, org, key name, plaintext, nonce,
   ephemeral key, marker) is committed once and exercised by both the
   Elixir and Rust suites, so the two implementations cannot drift.

4. **`fluxvale secrets encrypt` is the client.** `fluxvale secrets
   encrypt --org <id|slug> --key ENV_NAME` reads the plaintext from
   stdin (or `--from-file`), resolves the org's canonical id, fetches
   the public key, and prints one marker line. It refuses a TTY
   (no shell history, no argv), never echoes the input, and never
   prints the plaintext. The command is in the CLI, not the provider:
   provider functions are called on every plan and must be
   deterministic; encryption is neither.

5. **Only secret-typed inputs accept a marker.** The catalog already
   marks env fields with `secret: true`. A marker is valid only for
   those fields (and for keys outside the schema — operator-owned
   env). A marker on a `boolean`/`integer` typed non-secret field is
   refused with the key name; the plaintext type is unintelligible
   until opened, and a secret boolean is a modeling error. Plaintext
   values keep working everywhere — this is additive.

6. **Key management.** `mix flux_vale.secrets.new_key` prints one
   ring entry; the operator stores it in 1Password and sets
   `FLUXVALE_SECRET_KEY_RING` (a JSON list with an active `kid`).
   The ring holds retired keys for opening. Rotation = generate a new
   key, make it active, keep the old one in the ring. The platform
   never re-encrypts a user's Terraform state (it cannot reach it),
   so **an old key is retired only when every config using it has
   been re-encrypted** — retiring early is a loud, per-variable
   deploy failure, documented in the runbook. Losing the ring is
   unrecoverable: back up 1Password.

7. **Failure modes are loud and named.** Unknown `kid`, a bad tag, a
   wrong org, a wrong variable name, or a missing key all fail the
   update (`400`) or the deploy (`:error`) with a message naming the
   variable and the kid — never the value or ciphertext. A platform
   without a ring logs loudly at boot and refuses to encrypt (the
   public-key route has no active key); existing plaintext values
   still deploy.

8. **What an attacker with the ciphertext can do: nothing useful.**
   They cannot open it without the private key. They cannot move it
   to another org or variable (the associated data fails). Within the
   same org and variable, replaying it into a config they can already
   apply is equivalent to having deploy access — which already grants
   the ability to read the running app's env. No new capability.

9. **Platform-managed integrations keep minting their own secrets.**
   SSO mints the OIDC client secret; backing services generate their
   credentials. Terraform names the relationship (the SSO resource,
   the backing-service app version), never the credential. This ADR
   is only for **user-supplied** env values.

## Rejected alternatives

- **Terraform write-only / ephemeral inputs (1.11+).** The strongest
  state story — the value never enters state or plan at all — but
  write-only attributes cannot produce a plan diff on their own
  (Terraform cannot see a change), so every secret change needs a
  hand-bumped version attribute; secret removal needs a second
  protocol; and it imposes a Terraform floor the provider does not
  have (OpenTofu support was not verified for this draft). It also
  leaves the plaintext in HCL/variables if the user writes it there,
  and does nothing for the git-config surface. A good **future
  additive** input for users who want zero ciphertext in state;
  not the primary model.
- **Secret references (`op://`, `sops://`, `ssm://`) resolved at
  deploy.** Neither plaintext nor ciphertext in Terraform — the
  cleanest artifact story — but the platform would need egress to
  each store and a customer-scoped read credential held by the
  platform, turning a deploy into a runtime dependency on a
  third-party store and widening the platform's credential custody.
  It is a product integration per provider, not an env feature.
  Revisit trigger: a real customer asks for their own vault, and the
  credential-custody model is designed first.
- **Per-org keys.** See decision 2; it moves work without moving the
  trust boundary. Trigger: BYOK/customer-managed keys, or a
  compliance ask for per-tenant key custody.
- **Platform-side encryption API (`POST /secrets/encrypt`).** It
  would put the plaintext on the platform's wire and in its request
  path for no gain; client-side encryption keeps the plaintext where
  the user already has it.
- **A provider-defined `encrypt()` function.** Provider functions
  are called during plan and must be deterministic; a random
  ephemeral key makes the plan inconsistent, and a deterministic
  nonce leaks equality. The CLI is the right shape.
- **Leaving it to `sensitive` plus backend hygiene.** That is the
  status quo this ADR exists to replace; `sensitive` is a display
  flag, and the state bucket is where secrets actually leak.

## Consequences

- Users get one new step per secret: `fluxvale secrets encrypt`, then
  paste the marker. The docs teach it on the Terraform and CLI pages,
  and the encrypted mode is optional — plaintext keeps working.
- The platform DB stops holding plaintext for encrypted values; the
  K8s Secret still does (out of scope).
- The marker prefix is reserved; `enc:v1:raw:` is the escape.
- Key loss is unrecoverable by design; the runbook names the 1Password
  backup and the retirement rule.
- Rotation protects future encryptions; old ciphertexts stay openable
  until users re-encrypt, because Terraform state is not ours to
  rewrite.
- The `secret: true` catalog flag becomes actionable: those are the
  fields the CLI and docs tell users to encrypt.
- No migration, no new table, no new scope. One config secret, one
  CLI command, one resolver at the deploy seam.
