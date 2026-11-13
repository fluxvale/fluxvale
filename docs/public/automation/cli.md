---
title: CLI quickstart
description: Install the FluxVale CLI, sign in from the terminal, and manage apps without the browser.
order: 10
slug: cli
---

The `fluxvale` CLI drives the platform from your terminal. It covers the everyday loop: browse the catalog, deploy, start and stop, back up, and check the wallet.

## Install

```sh
curl -fsSL https://github.com/fluxvale/fluxvale/releases/latest/download/install.sh | sh
```

The script installs the binary under `~/.local/share/fluxvale/` and puts a launcher at `~/.local/bin/fluxvale`. Make sure that directory is on your `PATH`. Re-running the command upgrades in place.

Prebuilt archives exist for Linux amd64 and aarch64, macOS Apple silicon, and Windows x86_64. On Windows, download the archive from the releases page. There is no installer.

## Sign in

```sh
fluxvale auth login
```

The CLI prints a device code and opens the browser at the approval page. Approve there and the CLI stores a personal access token in your OS keychain. `fluxvale auth status` shows where the token lives, and `fluxvale whoami` proves it works.

## The everyday commands

Browse and inspect:

```sh
fluxvale apps list
fluxvale apps show kavita
```

Deploy an app and watch it come up:

```sh
fluxvale instances deploy --app kavita --name "Reading" --storage-gb 20
fluxvale instances status
```

The deploy flags set CPU cores, memory, and storage directly, and `--env KEY=VALUE` (repeatable) sets env vars at create. Leave them off for the app's defaults.

Change an env var on a live instance without destroying it:

```sh
fluxvale instances configure <instance-id> --env API_KEY=s3cr3t --remove OLD_KEY
```

`--env` adds or replaces, `--remove` deletes, everything else stays. Values are write-only: output names the changed keys, never their values.

Start, stop, and remove:

```sh
fluxvale instances stop reading
fluxvale instances start reading
fluxvale instances destroy reading --confirm
```

Destructive commands ask for `--confirm`. Without it the CLI sends nothing and prints the exact command to re-run.

Backups and wallet:

```sh
fluxvale backups configure reading --endpoint https://account.r2.cloudflarestorage.com --bucket my-bucket --access-key-id KEY
fluxvale backups run reading
fluxvale wallet balance
fluxvale topup --open
```

## JSON output

Every command takes `--output json` for scripting:

```sh
fluxvale instances list --output json
```

## Where to go next

- The [Terraform guide](/docs/automation/terraform) manages apps as code.
- The release notes live on the GitHub releases page, tagged `cli-v*`.
