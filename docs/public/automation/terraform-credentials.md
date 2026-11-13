---
title: Terraform credentials
description: Give Terraform a FluxVale token without pasting one into your shell — local development, CI, rotation, and revocation.
order: 25
slug: terraform-credentials
---

The FluxVale provider authenticates with the `FLUXVALE_PAT` environment variable. You never create that token by hand, and it never needs to sit in your shell.

## Local development

Sign in once. The CLI keeps the token in your OS keychain:

```sh
fluxvale auth login
```

Run Terraform or OpenTofu through `auth exec`. It loads the stored token, puts it in the child process's environment as `FLUXVALE_PAT`, and runs the command:

```sh
fluxvale auth exec -- tofu plan
fluxvale auth exec -- tofu apply
```

The variable exists only in that process. Your shell never sees it, and the CLI never prints it. Check both halves:

```sh
fluxvale auth exec -- sh -c 'test -n "$FLUXVALE_PAT" && echo token present in the child'
echo "${FLUXVALE_PAT:-empty in the parent shell}"
```

`auth exec` exits with the child's status, so a failed plan fails the wrapper unchanged.

Point at another environment with `--config`: the file's `base_url` selects the environment, and `auth exec` uses that environment's stored sign-in.

## CI and containers

A pipeline has no keychain. Mint a scoped, short-lived token on a trusted machine and store it in the pipeline's secret store:

```sh
fluxvale auth token \
  --name github-actions-terraform \
  --scopes instances:read,instances:write,backups:read,backups:write,gateways:read,gateways:write,catalog:read \
  --ttl 1h
```

The command prints the token once to stdout and nothing else, so pipe it straight into the secret store — it never touches disk:

```sh
fluxvale auth token --scopes instances:read --ttl 1h | gh secret set FLUXVALE_PAT
```

A minted token is bounded by the sign-in that created it: it can only carry scopes that sign-in already holds, and it never expires after it. The platform also caps any token at one year, so use minutes or hours for CI. The one-line summary (name, scopes, expiry) goes to stderr; stdout is only the value.

In the pipeline, give the plan and apply steps the secret:

```yaml
- run: tofu apply -auto-approve
  env:
    FLUXVALE_PAT: ${{ secrets.FLUXVALE_PAT }}
```

Scopes by resource:

- `instances:read` / `instances:write` — instances, deploys, resizes, env updates, hostnames.
- `backups:read` / `backups:write` — backup settings and runs.
- `gateways:read` / `gateways:write` — access gateways and custom domains.
- `catalog:read` — apps and app versions.

`wallet:read` is not needed by the provider. A `write` scope includes its domain's read.

## Rotation and revocation

Rotate by minting a replacement with the same scopes, updating the secret store, then revoking the old token in the panel at [API tokens](/settings/developer#api-tokens). Revocation is immediate: the next plan fails with 401.

`fluxvale auth logout` removes the local sign-in token only; tokens already minted for CI keep working until they expire or are revoked. Short TTLs make a forgotten token die on its own.
