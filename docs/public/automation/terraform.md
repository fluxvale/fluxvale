---
title: Terraform provider
description: Manage FluxVale apps, backups, sign-in wiring, gateways, and domains as infrastructure code.
order: 20
slug: terraform
---

The FluxVale provider manages your apps with Terraform or OpenTofu. It covers the same ground as the panel: instances, backups, private-access gateways, custom domains, and PocketID sign-in wiring.

The provider is on the public registry at [registry.terraform.io/fluxvale/fluxvale](https://registry.terraform.io/providers/fluxvale/fluxvale/latest). Declare it under Configure and run `terraform init` — or `tofu init`: OpenTofu honors the explicit `registry.terraform.io` source the same way, signed downloads included.

## Install the provider

The provider's source and releases live in [fluxvale/terraform-provider-fluxvale](https://github.com/fluxvale/terraform-provider-fluxvale).

There is no manual install step. The `required_providers` block under Configure names the registry source, and `terraform init` or `tofu init` pulls the signed provider from it.

Offline and air-gapped machines cannot reach the registry. For those, mirror a release archive locally and point the tool at it:

1. Download the zip for your platform from the [releases page](https://github.com/fluxvale/terraform-provider-fluxvale/releases) — adjust the file names below to the platform and version you took — together with the versioned checksums `terraform-provider-fluxvale_0.4.0_SHA256SUMS`. Verify the archive:

   ```sh
   grep terraform-provider-fluxvale_0.4.0_linux_amd64.zip terraform-provider-fluxvale_0.4.0_SHA256SUMS | sha256sum -c -   # macOS: shasum -a 256 -c -
   ```

2. Create the mirror tree and place the zip:

   ```sh
   mkdir -p ~/.tfplugins-mirror/registry.terraform.io/fluxvale/fluxvale
   cp terraform-provider-fluxvale_0.4.0_linux_amd64.zip ~/.tfplugins-mirror/registry.terraform.io/fluxvale/fluxvale/
   ```

3. Point the tool at the mirror in `~/.terraformrc` for Terraform or `~/.tofurc` for OpenTofu, with the absolute path to your mirror:

   ```hcl
   provider_installation {
     filesystem_mirror {
       path    = "/home/you/.tfplugins-mirror"
       include = ["registry.terraform.io/fluxvale/fluxvale"]
     }
     direct {}
   }
   ```

The mirror path skips the registry's signed-manifest verification. Releases also carry detached signatures (`_SHA256SUMS.sig`); the provider repository documents how to verify them against its public key.

## Configure

```hcl
terraform {
  required_providers {
    fluxvale = {
      source  = "registry.terraform.io/fluxvale/fluxvale"
      version = "~> 0.4" # write-only secret_env_vars needs 0.4.0+
    }
  }
}

provider "fluxvale" {}
```

The provider needs a personal access token. Export it as an environment variable:

```sh
export FLUXVALE_PAT=fvpat_your_token
```

The token attribute exists on the provider block too, but the environment variable keeps the secret out of your `.tf` files. Without a working token, `terraform plan` fails immediately.

## The resources

`fluxvale_instance` deploys an app. Pick the catalog app by slug, set the allocation, and the provider creates, deploys, and later resizes the instance:

```hcl
data "fluxvale_app_versions" "kavita" {
  app = "kavita"
}

resource "fluxvale_instance" "reading" {
  name          = "Reading"
  app_version_id = data.fluxvale_app_versions.kavita.app_versions[0].id
  cpu_cores     = 0.5
  memory_mb     = 512
  storage_gb    = 20
}
```

The versions data source lists the app's versions newest first
(semver — a pre-release like `3.4.1-bundled` sits below its release),
so `app_versions[0]` is the newest. Pinning a specific version id
instead keeps deploys on one release as the catalog grows.

The full resource set:

- `fluxvale_instance` deploys an app, with allocation, environment inputs, run state, and exposure.
- `fluxvale_instance_backups` sends backups to your own S3-compatible bucket.
- `fluxvale_access_gateway` runs the private-access gateway for your organization.
- `fluxvale_custom_domain` registers your own domain on the private edge. See the [custom domains guide](/docs/guides/custom-domains) for what verification means.
- `fluxvale_pocket_id_sso` wires an instance's sign-in to your PocketID instance.
- Data sources `fluxvale_apps` and `fluxvale_app_versions` read the catalog; `fluxvale_instance` reads one existing instance by id or slug.

The worked example in the provider's repository, under [`examples/personal-stack`](https://github.com/fluxvale/terraform-provider-fluxvale/tree/main/examples/personal-stack), composes the instance, backup, gateway, and domain resources into one stack.

### Environment variables update in place

`env_vars` merges over the app version's defaults server-side. Changing the map updates the instance in place — no replacement — and keys the resource previously set that you stop naming are removed:

```hcl
resource "fluxvale_instance" "reading" {
  # …
  env_vars = {
    SMTP_HOST = "smtp.example.com"
    SMTP_PORT = "587"
  }
}
```

Deployer-owned keys — the OIDC recipe, backing service URLs, and the instance URL — are refused on set and skipped on remove. The app's first-run contract `env` keys are fixed: a set or remove is refused, and a contract `env` key already in state dead-ends until you remove it from state and configuration by hand. Contract `forbidden_env` keys refuse a set but allow a remove. A null element is rejected: remove the key instead (an empty string is a value). The API never echoes the map, so a plan cannot see server-side drift by design, and the configured values are kept in state.

### Secrets never enter state

`sensitive` only hides a value in the console; the plaintext still lands in state and plan files. For values that must never be written there, use the write-only `secret_env_vars` map with its rotation integer. The attributes need provider 0.4.0+ and Terraform 1.12+ or OpenTofu 1.13+. The encryption block below is OpenTofu-only; Terraform users should keep backend encryption at rest.

Mark the input `ephemeral = true` as well as `sensitive = true`: Terraform then keeps the variable value out of the saved plan too. Applying a saved plan requires supplying the variable again (`TF_VAR_smtp_password=…`), because an ephemeral value is never stored.

```hcl
variable "smtp_password" {
  type      = string
  sensitive = true
  ephemeral = true
}

variable "state_passphrase" {
  type      = string
  sensitive = true
}

terraform {
  required_version = ">= 1.13.0" # OpenTofu: write-only inputs + state/plan encryption

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase # export TF_VAR_state_passphrase from your keychain
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

resource "fluxvale_instance" "reading" {
  # …
  secret_env_vars         = { SMTP_PASSWORD = var.smtp_password }
  secret_env_vars_version = 1
}
```

On Terraform 1.12+, drop the `encryption` block, change `required_version` to `>= 1.12.0`, and rely on your backend's encryption at rest; the instance inputs are the same:

```hcl
resource "fluxvale_instance" "reading" {
  # …
  secret_env_vars         = { SMTP_PASSWORD = var.smtp_password }
  secret_env_vars_version = 1
}
```

The values never appear in `terraform.tfstate` or the saved plan. Because Terraform cannot see a write-only change, the version integer is the rotation signal: change a value and bump it, and bump on any key add, removal, or move between the two maps. Removing a key is drop-key-plus-bump; a key-set change with an unchanged version is refused. The computed `secret_env_vars_keys` list is how the provider tracks which keys it manages. A key in both `env_vars` and `secret_env_vars` is a plan-time error when both maps are known; if `secret_env_vars` is unknown at plan time the overlap check runs at apply, where an overlap fails the update and a still-unknown map skips the update with a warning. With no secrets, leave both attributes unset. Proving it after an apply — on an encrypted state, grep the decrypted form:

```sh
tofu state pull | grep -c 'the-secret-value'
# 0
```

The platform rolls a running app after an env change. If the app's quota cannot fit a second pod during that rollout, stop it (`running = false`), apply the bump, then start it again (`running = true`); otherwise the rollout can mark the instance `error`.

Write-only inputs need Terraform 1.12+ or OpenTofu 1.13+ and provider 0.4.0+. Existing configurations need no change, and older CLIs can keep using `env_vars` with state encryption at rest. The provider's [Secrets in Terraform guide](https://github.com/fluxvale/terraform-provider-fluxvale/blob/main/docs/guides/secrets.md) has the full ladder, the unencrypted-state migration, and the OpenTofu AWS KMS, GCP KMS, Azure Key Vault, and OpenBao key variants.

### Read an existing instance

`fluxvale_instance` is also a data source, for an instance managed in another stack or outside Terraform:

```hcl
data "fluxvale_instance" "wiki" {
  slug         = "velvety-otter-1234"
  organization = "acme" # id or slug; optional when your token spans one org
}
```

Read by `id` (always unambiguous) or `slug`. A slug is unique only per cluster, so pass `organization` when your token spans several (it falls back to the provider-level `organization`). If a slug still matches more than one instance in one organization, the API answers `multiple_results` — use the `id`. Your token's memberships decide what is visible — an instance in another organization reads as not found.

### Wire PocketID sign-in

`fluxvale_pocket_id_sso` connects an instance's sign-in to your PocketID instance. One wiring per instance; the resource's `id` is the instance id. The PocketID instance must be public and have held-key custody (its API key stored once); the platform refuses the connect otherwise.

```hcl
resource "fluxvale_pocket_id_sso" "vault" {
  instance_id           = fluxvale_instance.vaultwarden.id
  pocket_id_instance_id = fluxvale_instance.pocket_id.id # a public PocketID instance in the same organization, with its API key stored (held-key custody)
  rotate_secret_on      = "2026-11-13"                  # bump to rotate the client secret in place
}
```

`rotate_secret_on` is a rotation trigger, not a replacement: changing it mints a second active secret, applies it to the workload, then deletes the old one once the workload patch is accepted — the client id and the resource id survive. The delete is best effort: a refused PocketID delete leaves the old secret active there, so check and remove it by hand. Pods still on the old value return 401 until the rollout cycles them. Changing `instance_id` or `pocket_id_instance_id` replaces the wiring (disconnect and a fresh client). The client secret's value never travels through Terraform; the platform writes it into the instance's environment. Connect, disconnect, and rotate are gated by the platform's `pocketid_sso_wiring` flag (seeded enabled); the wiring read stays available while the flag is off.

## Promote existing resources

The panel, the CLI, and the MCP server can create resources the provider can also manage. When the estate already exists, generate the import scaffold instead of writing every block by hand:

```sh
fluxvale terraform import --org acme --out infra/fluxvale
cd infra/fluxvale
tofu init
tofu plan -generate-config-out=generated.tf
tofu apply
```

`--out` defaults to the current directory, and the command refuses to overwrite an existing file. It writes three files:

- `versions.tf` — the registry source, the provider block, and a commented state-encryption block pointing at the OpenTofu state-encryption guide.
- `imports.tf` — one `import` block per live instance, backup setting, access gateway, and custom domain, plus commented blocks for PocketID SSO wirings (the provider does not implement `import` for them yet). Addresses come from slugs or names, with a numeric suffix when two sanitize to the same label. Import ids follow each resource's own shape: the instance id for instances, the instance id for backups and SSO, the org id or slug for the gateway, and the access-domain id for a domain.
- `README.md` — the three commands above plus the caveats below.

No resource bodies are rendered. `-generate-config-out` is the official, provider-schema-aware writer; hand-rendered HCL would rot as the schema moves.

The MCP tool `terraform_import_bundle` returns the same three files (path and content) without writing anywhere. The CLI stamps its configured base URL into `versions.tf` when it differs from the provider's production default; the MCP tool leaves the provider on that default unless the caller passes `api_url` (for staging, pass `https://staging.fluxvale.com` — the server's own upstream URL can be cluster-internal). It reads instances, backup settings, the access gateway, and custom domains, so its full scope set is `instances:read` + `backups:read` + `gateways:read`.

### Caveats

- **Write-only values are never readable back.** `generated.tf` cannot carry `env_vars` or a backup's `secret_access_key`. Re-add `env_vars` in your Terraform config from your own records after adoption — the provider writes them in place; set the backup secret in the panel. The `enc:v1:` marker path in [ADR-0053](https://github.com/fluxvale/fluxvale/blob/main/docs/adr/00053-terraform-secret-env.md) is design-only; the write-only `secret_env_vars` input is available from 0.4.0.
- **Generated config may need small edits before a clean plan.** `app`/`app_version` on an imported instance have no wire echo, the gateway's `instances` set is config-authoritative and starts null, and `rotate_secret_on` is config-only posture. Fill in what you want Terraform to manage, then re-plan.
- **Only user-owned domains are exported.** The org's system-minted `platform` access domain is skipped; `fluxvale_custom_domain` manages `custom` rows.
- **PocketID SSO import is a provider gap.** The provider does not implement `import` for `fluxvale_pocket_id_sso` yet. The scaffold comments those blocks out, with the instance id as the import id; uncomment them once the provider release you use supports import. Live `deleting` and `lost` instances are skipped for the same reason — there is no remote object to adopt.
- **Gateway attachments are not discoverable.** The API has no attachment list, so `instances` stays null after import. Add the set by hand if Terraform should own it.

## Compatibility

The provider follows the platform's API, and 0.x may still adjust computed fields and add attributes. The published [compatibility notes](https://github.com/fluxvale/terraform-provider-fluxvale/blob/main/docs/guides/compatibility.md) state which names are stable from day one: the provider configuration, the `FLUXVALE_PAT` variable, and every resource and data source name listed above. Config you write against those names keeps working.

From 0.3.0, `env_vars` updates in place; it is write-only on the wire — never echoed — but a normal Terraform attribute, not a Terraform write-only attribute. Plaintext values still live in state.

`secret_env_vars`, `secret_env_vars_version`, and the computed `secret_env_vars_keys` are additive: existing configurations need no change. The new attributes require Terraform 1.12+ or OpenTofu 1.13+ and provider 0.4.0+; on an older CLI, leave them out and use `env_vars` plus state encryption at rest.
