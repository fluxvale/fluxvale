# ADR-0051: The Terraform/OpenTofu provider leaves the monorepo — fluxvale/terraform-provider-fluxvale, registry-ready

**Status**: Accepted
**Date**: 2026-11-11

**Context**: [ADR-0019](00019-machine-first-api-cli-mcp.md) Am. 4 landed
the provider at `apps/tfprovider` and deliberately deferred the public
registries ("a dedicated `terraform-provider-fluxvale` repo + GPG
signing — deferred until a second user exists"). Both the Terraform
Registry and OpenTofu's registry list a provider from a dedicated,
semver-tagged `terraform-provider-<name>` repo connected to the org —
a provider living in a subdirectory of the platform monorepo under
namespaced `tf-v*` tags can never appear in `terraform init`. The
owner committed on Nov 11 (#705): full extraction now, supersedes the
thin-mirror idea — the real source moves.

**Decision**:

1. **The provider lives in its own public repo**:
   [`fluxvale/terraform-provider-fluxvale`](https://github.com/fluxvale/terraform-provider-fluxvale).
   The registry address is unchanged
   (`registry.terraform.io/fluxvale/fluxvale`) — only the code's home
   moves, so no user config changes. The Go module path renames to
   `github.com/fluxvale/terraform-provider-fluxvale`.

2. **History is preserved**: `git filter-repo --subdirectory-filter
   apps/tfprovider` carried the provider's 9 commits (all
   owner-authored) into the new repo — blame and provenance survive.
   The old `tf-v0.1.x` tags and releases stay on the monorepo; the new
   repo's registry history starts at `v0.2.0` (no re-tagged 0.1.x —
   they would alias releases that live elsewhere).

3. **Registry readiness ships with the move**: plain `vX.Y.Z` tags
   (semver, no namespace — the provider is the repo's sole product);
   the registries' release-asset convention — per-platform zips
   carrying only the binary, plus versioned
   `terraform-provider-fluxvale_<version>_manifest.json` (protocol
   6.0), `_SHA256SUMS` covering the zips and the manifest, and the
   binary GPG-detached `_SHA256SUMS.sig` — over a dedicated company
   key (RSA 4096, no expiry — private half in 1Password
   `fluxvale-production/terraform-provider-signing-key` + the repo's
   `GPG_PRIVATE_KEY` Actions secret; public half committed in the
   repo). First release: **v0.2.0** — no schema break, but the
   distribution artifact changes materially (manifest, signatures,
   new download home), which is minor-bump-sized, not patch-sized.

4. **Detachment audit result**: the provider shares nothing with the
   monorepo's Rust workspaces — `crates/fluxvale-api` serves the CLI
   and MCP only; the Go module was already self-contained. The move is
   a module-path rename plus the provider's own `mise.toml`, CI, and
   release engineering. Nothing is vendored.

5. **The monorepo keeps**: the public automation doc
   (`docs/public/automation/terraform.md`, rendered at
   `/docs/automation/terraform`) — it points at the new repo. The
   nightly pentest's `dep-audit` keeps its hex half; the govulncheck
   half moved with the Go code.

**Consequences**:

- The registry listing itself stays a manual owner step (HCP org
  connect + GPG public key upload); the repo is ready for it, and the
  listing goes live when that step lands. Until then the install story
  stays manual-first (filesystem mirror), unchanged.
- The fleet repo (`fluxvale/infrastructure`) follows the release home:
  `tofu/owner-stack` pins and the CI mirror step point at the new
  repo's releases.
- Provider bugs track in the new repo's issues (open provider issues
  transferred at extraction); platform/API bugs stay here.
- The acceptance lane's secrets (`TF_ACC_*`) were never filed on the
  monorepo and now belong to the new repo — same tiered posture as
  before.

Rejected: the thin mirror (a stub repo pointing at monorepo releases —
the registries' listing requirement makes it the worst of both), and a
fresh-import history cut (needlessly discards provenance for a path
with 9 clean commits).

## Amendment 1 (2026-11-11): the registry listing is live — the install story is registry-first

The owner step landed the same day: registry.terraform.io lists
`fluxvale/fluxvale` (v0.2.1, signed — the planned v0.2.0 was never
tagged publicly; the first public release shipped as v0.2.1). The
"until then" clause above is
history — `/docs/automation/terraform` now teaches `terraform init`
(and `tofu init`, which honors the explicit `registry.terraform.io`
source the same way — verified against OpenTofu 1.13.1 and 1.13.9)
with the filesystem mirror demoted to the offline and air-gapped path.
