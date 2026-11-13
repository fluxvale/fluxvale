# Changelog

All notable changes to the FluxVale CLI land here, one section per
released version. This file is what the release workflow publishes from:
a `cli-v*` release body is the matching section below plus the sign-in
primer, so write the section before tagging.

Changelog policy: one changelog per shipped artifact. The CLI ships as
versioned release artifacts and keeps this file. The FluxVale platform is
a continuously deployed service with no versioned artifacts, so its
user-facing record is the feedback board and the roadmap instead of a
file. That is revisited only if the platform ever ships a versioned
artifact.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow semver.

## [Unreleased]

### Added

- `auth exec -- <command>`: run a command with the stored sign-in token
  in its environment as `FLUXVALE_PAT`, and only there. `fluxvale auth
  exec -- tofu apply` is the Terraform UX — no token in the shell, no
  token on screen.
- `auth token --scopes <list> --ttl <duration>`: mint a scoped,
  short-lived token for CI or a container. It prints once to stdout for
  the caller's secret store, never writes to disk, and can only narrow
  the sign-in that minted it (scopes and lifetime).
- `terraform import --org <slug> [--out <dir>]`: discover an
  organization's live instances, backup settings, access gateway, custom
  domains, and PocketID SSO wirings, then write `versions.tf`,
  `imports.tf`, and `README.md` for `tofu plan -generate-config-out`.
  The scaffold imports resources; it never hand-renders their bodies.
- `instances deploy --env KEY=VALUE` sets env vars at create, and
  `instances configure <id> --env KEY=VALUE --remove KEY` merges them
  on a live instance. Values are write-only — output names the changed
  keys, never their values.
- `instances status` and `instances deploy` show the instance's public
  URL.

## [0.1.0] - 2026-11-05

### Added

- The `fluxvale` command line: `auth`, `apps`, `instances`, `backups`,
  `access`, and `wallet` command groups plus `whoami` and `topup`. One
  self-contained binary, no language runtime to install.
- Sign in with the device flow: `auth login` prints a code and opens the
  approval page, the token lands in your OS keychain, `auth status`
  shows who you are signed in as, `auth logout` removes it. On a host
  without a keychain the token is saved to a file readable only by your
  user (0600).
- Browse the catalog: `apps list`, `apps show <slug>`.
- Deploy and manage instances: `instances deploy --app <slug>`, plus
  `list`, `status`, `stop`, `start`, and `destroy --confirm`.
- Backups: point an instance at your S3 (`backups configure`), run and
  track backups (`run`, `status`), and restore a volume from a run
  (`restore --from <run> --confirm`).
- Private access: `access status`, `attach`, `detach`, and `resume` for
  gateway-only access to your instances.
- Wallet: `balance`, `runway`, and `ledger`, with your organization
  auto-resolved, plus `topup` (`--open` launches the browser).
- Scripting: `--output json` on reads and `--config <path>` to point at
  another environment.
- Releases: checksummed archives for linux-amd64, linux-aarch64,
  macos-aarch64, and windows-x86_64 on GitHub Releases, a
  sha256-verified install one-liner, and `FLUXVALE_VERSION` pinning.
