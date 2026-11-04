# fluxvale — the FluxVale CLI

Install apps from the FluxVale catalog, manage your instances, backups,
access, and wallet from the command line. A single self-contained
binary — no language runtime to install.

FluxVale is a managed platform for open-source apps: browse the catalog,
install, and an instance is running on its own HTTPS subdomain. The CLI
does what the web app does — for when you'd rather type. A single
self-contained binary: no language runtime to install.

## Install

Download the archive for your machine from
[GitHub Releases](https://github.com/fluxvale/fluxvale/releases), unpack
it, and put `fluxvale` on your PATH. Verify the download (unix):

```
grep <your-archive> SHA256SUMS | sha256sum -c -
```

On Windows, compare by eye:

```
certutil -hashfile <your-archive> SHA256
```

Archives: `linux-amd64`, `linux-aarch64`, `macos-aarch64` (Apple
silicon), `windows-x86_64` — `.tar.gz` on unix, `.zip` on Windows.

## Sign in

```
fluxvale auth login     # prints a code, opens the approval page
                        # compare the code, click Approve
                        # the token lands in your OS keychain — done
```

The token never appears on screen; `fluxvale auth logout` removes it.

## Commands

| Command | What it does |
|---|---|
| `fluxvale auth login` | Sign in — the device flow (approve in the browser) |
| `fluxvale auth logout` | Remove the stored token |
| `fluxvale auth status` | Show who you're signed in as, and where the token lives |
| `fluxvale whoami` | Show the signed-in user |
| `fluxvale apps list` / `apps show <slug>` | Browse the app catalog |
| `fluxvale instances list` | List your instances |
| `fluxvale instances status [id]` | One instance's status, or a verbose list |
| `fluxvale instances deploy --app <slug>` | Install an app — a new running instance |
| `fluxvale instances stop/start <id>` | Pause and resume an instance |
| `fluxvale instances destroy <id> --confirm` | Delete an instance and ALL its data |
| `fluxvale backups configure <id> --endpoint … --bucket … --access-key-id …` | Point an instance's backups at your S3 |
| `fluxvale backups run <id>` | Run a backup now |
| `fluxvale backups status <id>` | Track the latest backup run |
| `fluxvale backups restore <id> --from <run> --confirm` | Restore the volume from a backup run (overwrites it) |
| `fluxvale access status/attach/detach/resume` | Private access to your instances over the gateway (`access create` is panel-first) |
| `fluxvale wallet balance` | Your prepaid credit balance (org auto-resolved) |
| `fluxvale wallet runway` | How long your balance lasts at current spend |
| `fluxvale wallet ledger` | The credit history |
| `fluxvale topup` | Open the top-up page (`--open` launches the browser) |

Global flags: `--config <path>` (default
`<config dir>/fluxvale/config.toml` — put `base_url` there to point at
another environment), `--output json` for scripts.

## Building from source

A Rust toolchain pinned in `rust-toolchain.toml` — `rustup` reads it and
installs the exact version. Then the gates CI runs:

```
cd cli
cargo build --release
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo xtask openapi --check
# cargo-deny is a separate binary — ci.yml installs the pinned
# cargo-deny@0.20.2
cargo deny check licenses advisories
```
