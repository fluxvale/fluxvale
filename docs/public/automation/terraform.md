---
title: Terraform provider
description: Manage FluxVale apps, backups, sign-in wiring, gateways, and domains as infrastructure code.
order: 20
slug: terraform
---

The FluxVale provider manages your apps with Terraform or OpenTofu. It covers the same ground as the panel: instances, backups, private-access gateways, custom domains, and PocketID sign-in wiring.

The provider is on the public registry at [registry.terraform.io/fluxvale/fluxvale](https://registry.terraform.io/providers/fluxvale/fluxvale/latest). Declare it under Configure and run `terraform init` or `tofu init`. OpenTofu honors the explicit `registry.terraform.io` source the same way, signed downloads included.

## Install the provider

The provider's source and releases live in [fluxvale/terraform-provider-fluxvale](https://github.com/fluxvale/terraform-provider-fluxvale).

There is no manual install step. The `required_providers` block under Configure names the registry source, and `terraform init` or `tofu init` pulls the signed provider from it.

Offline and air-gapped machines cannot reach the registry. For those, mirror a release archive locally and point the tool at it:

1. Download the zip for your platform from the [releases page](https://github.com/fluxvale/terraform-provider-fluxvale/releases) (adjust the file names below to the platform and version you took) together with the versioned checksums `terraform-provider-fluxvale_0.6.0_SHA256SUMS`. Verify the archive:

   ```sh
   grep terraform-provider-fluxvale_0.6.0_linux_amd64.zip terraform-provider-fluxvale_0.6.0_SHA256SUMS | sha256sum -c -   # macOS: shasum -a 256 -c -
   ```

2. Create the mirror tree and place the zip:

   ```sh
   mkdir -p ~/.tfplugins-mirror/registry.terraform.io/fluxvale/fluxvale
   cp terraform-provider-fluxvale_0.6.0_linux_amd64.zip ~/.tfplugins-mirror/registry.terraform.io/fluxvale/fluxvale/
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

The mirror path skips the registry's signed-manifest verification. Releases also carry detached signatures (`_SHA256SUMS.sig`). The provider repository documents how to verify them against its public key.

## Configure

```hcl
terraform {
  required_providers {
    fluxvale = {
      source  = "registry.terraform.io/fluxvale/fluxvale"
      version = "~> 0.6" # gateway mint enrollment needs 0.6.0+
    }
  }
}

provider "fluxvale" {}
```

The provider reads a personal access token from `FLUXVALE_PAT`. For local work, sign in once and let the CLI inject it for a single command. The token stays in your keychain (or the 0600 fallback file) and out of your shell:

```sh
fluxvale auth login
fluxvale auth exec -- tofu plan
```

For CI or a container, mint a scoped, short-lived token and store it in the pipeline's secret store: see [Terraform credentials](/docs/automation/terraform-credentials). The token attribute exists on the provider block too, but the environment variable keeps the secret out of your `.tf` files. Without a working token, `terraform plan` fails immediately.

## The resources

### Create the organization

Every deploy needs an organization, which is the ownership and billing boundary. `fluxvale_organization` creates a team organization and makes the authenticated user its owner. The resource ships in provider **v0.5.0** (any `>= 0.5` pin covers it, and the `~> 0.6` pin above already does). On v0.4 the resource type does not exist:

```hcl
resource "fluxvale_organization" "team" {
  name = "Acme"
  slug = "acme"

  lifecycle {
    prevent_destroy = true
  }
}

resource "fluxvale_instance" "reading" {
  organization   = fluxvale_organization.team.slug
  name           = "Reading"
  app_version_id = data.fluxvale_app_versions.kavita.app_versions[0].id
  cpu_cores      = 0.5
  memory_mb      = 512
  storage_gb     = 20
}
```

The `organization` line is the dependency edge: the org exists before the instance, and Terraform destroys the instance before the org. Name the org on each resource rather than in the provider block, because a provider-level `organization` that references the resource makes provider configuration depend on a resource, which Terraform cannot destroy cleanly.

Creating an org does not fund it. A team org has no wallet and no welcome credit, so the first deploy still meets the platform's top-up gate. `name` updates in place. `slug` is create-only: changing it plans a replacement, and the provider rejects that plan because a replacement would destroy the org and everything under it. Renaming the slug is the panel's flow, so set the config to the current slug (or re-import) after an out-of-band rename.

Deleting an org is allowed only when it is empty: no instances, custom domains, gateway, non-owner members, and no billing history. An org that has ever held a wallet row is retained, because deleting it would delete financial records the platform keeps (see the [privacy policy](https://fluxvale.com/policies/privacy)). The row appears on the first visit to the org's home or billing page, a top-up, or a deploy, so even a never-funded org becomes undeletable once a member opens it. The provider surfaces the platform's refusal verbatim. `prevent_destroy` is the recommended posture for any org you care about, since the empty-org guard is the only thing standing between a stray `destroy` and the billing boundary.

Reserved brand slugs (`fluxvale`, `docs`, `app`, …) cannot be created through the API, even by a platform admin's token, because a token is never an operator act. Create the company org in the panel as a platform admin, then import it:

```sh
terraform import fluxvale_organization.team fluxvale
```

A token that is not a member of the org gets the same `404` as a missing id, so the platform never reveals a hidden org's existence.

### Deploy an app

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
(semver, where a pre-release like `3.4.1-bundled` sits below its release),
so `app_versions[0]` is the newest. Pinning a specific version id
instead keeps deploys on one release as the catalog grows.

The full resource set:

- `fluxvale_organization` creates a team organization, and supports reading, renaming, importing by slug, and deleting an empty org.
- `fluxvale_instance` deploys an app, with allocation, environment inputs, run state, and exposure.
- `fluxvale_instance_backups` sends backups to your own S3-compatible bucket.
- `fluxvale_access_gateway` runs the private-access gateway for your organization.
- `fluxvale_custom_domain` registers your own domain on the private edge. See the [custom domains guide](/docs/guides/custom-domains) for what verification means.
- `fluxvale_pocket_id_sso` wires an instance's sign-in to your PocketID instance.
- Data sources `fluxvale_apps` and `fluxvale_app_versions` read the catalog. `fluxvale_instance` reads one existing instance by id or slug. `fluxvale_domain_delegation` returns the DNS records a custom domain needs **before** registration.

The worked example in the provider's repository, under [`examples/personal-stack`](https://github.com/fluxvale/terraform-provider-fluxvale/tree/main/examples/personal-stack), composes the instance, backup, gateway, and domain resources into one stack.

### Environment variables update in place

`env_vars` merges over the app version's defaults server-side. Changing the map updates the instance in place (no replacement), and keys the resource previously set that you stop naming are removed:

```hcl
resource "fluxvale_instance" "reading" {
  # …
  env_vars = {
    SMTP_HOST = "smtp.example.com"
    SMTP_PORT = "587"
  }
}
```

Deployer-owned keys (the OIDC recipe, backing service URLs, and the instance URL) are refused on set and skipped on remove. The app's first-run contract `env` keys are fixed: a set or remove is refused, and a contract `env` key already in state dead-ends until you remove it from state and configuration by hand. Contract `forbidden_env` keys refuse a set but allow a remove. A null element is rejected: remove the key instead (an empty string is a value). The API never echoes the map, so a plan cannot see server-side drift by design, and the configured values are kept in state.

### Secrets never enter state

`sensitive` only hides a value in the console, and the plaintext still lands in state and plan files. For values that must never be written there, use the write-only `secret_env_vars` map with its rotation integer. The attributes need provider 0.4.0+ and Terraform 1.12+ or OpenTofu 1.13+. The encryption block below is OpenTofu-only. Terraform users should keep backend encryption at rest.

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

On Terraform 1.12+, drop the `encryption` block, change `required_version` to `>= 1.12.0`, and rely on your backend's encryption at rest. The instance inputs are the same:

```hcl
resource "fluxvale_instance" "reading" {
  # …
  secret_env_vars         = { SMTP_PASSWORD = var.smtp_password }
  secret_env_vars_version = 1
}
```

The values never appear in `terraform.tfstate` or the saved plan. Because Terraform cannot see a write-only change, the version integer is the rotation signal: change a value and bump it, and bump on any key add, removal, or move between the two maps. Removing a key is drop-key-plus-bump, and a key-set change with an unchanged version is refused. The computed `secret_env_vars_keys` list is how the provider tracks which keys it manages. A key in both `env_vars` and `secret_env_vars` is a plan-time error when both maps are known. If `secret_env_vars` is unknown at plan time the overlap check runs at apply, where an overlap fails the update and a still-unknown map skips the update with a warning. With no secrets, leave both attributes unset. To verify after an apply on an encrypted state, grep the decrypted form:

```sh
tofu state pull | grep -c 'the-secret-value'
# 0
```

The platform rolls a running app after an env change. The rollout takes the old pod down before the new one starts (one pod at a time, within the instance's existing quota), so expect a short restart and no stop/start.

Write-only inputs need Terraform 1.12+ or OpenTofu 1.13+ and provider 0.4.0+. Existing configurations need no change, and older CLIs can keep using `env_vars` with state encryption at rest. The provider's [Secrets in Terraform guide](https://github.com/fluxvale/terraform-provider-fluxvale/blob/main/docs/guides/secrets.md) has the full ladder, the unencrypted-state migration, and the OpenTofu AWS KMS, GCP KMS, Azure Key Vault, and OpenBao key variants.

### Wire a Cloudflare domain end to end

A custom domain needs one DNS record for private access: the
`_acme-challenge` delegation. Get it from the row-free data source,
create it before registration, then wait for issuance. The graph is
deliberately data source → record → domain: `fluxvale_custom_domain` has
no `dns_records` attribute, because Terraform does not publish a
resource's computed values until create returns, and create is waiting
for the record. The platform API keeps its own computed mirror for the
panel, while the provider exposes the pre-registration source only.

```hcl
data "cloudflare_zone" "this" {
  filter = {
    name = "example.com"
  }
}

data "fluxvale_domain_delegation" "apps" {
  domain = "apps.example.com"
}

resource "cloudflare_dns_record" "challenge" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = data.fluxvale_domain_delegation.apps.dns_records[0].name
  type    = data.fluxvale_domain_delegation.apps.dns_records[0].type
  content = data.fluxvale_domain_delegation.apps.dns_records[0].value
  proxied = false # mandatory: a proxied CNAME breaks the delegation
  ttl     = 300
}

resource "fluxvale_custom_domain" "apps" {
  domain                = "apps.example.com"
  wait_for_verification = true
  depends_on            = [cloudflare_dns_record.challenge]
}
```

The platform's cert-manager DNS-01 solver runs
`dns01.cnameStrategy: Follow`, so it follows the `_acme-challenge`
CNAME into its validation namespace. `proxied = false` is mandatory: a
proxied CNAME breaks that follow.

There is no host CNAME: the name resolves only through the claiming
gateway's tailnet. The worked example in the provider's repository,
[`examples/cloudflare-stack`](https://github.com/fluxvale/terraform-provider-fluxvale/tree/main/examples/cloudflare-stack),
adds the gateway and its write-only Tailscale API token to the same
stack, ordered after the domain, so the claim lands in the same apply.

The example targets Cloudflare provider v5. On v4 the record resource is `cloudflare_record` and the zone data source takes `name` directly instead of `filter`. The record fields are otherwise the same.

### Claim a verified domain from the same stack

`fluxvale_access_gateway.api_token` saves the Tailscale API token the
platform uses to claim verified domains. It is write-only: the value
never enters state or plan, and the API never echoes it. State keeps
`token_set_at` (the rotation clock) and `claimed_domains` (the claim
registry's readable half).

```hcl
variable "tailnet_domain" {
  type = string
}

variable "tailscale_api_token" {
  type      = string
  sensitive = true
  ephemeral = true
}

resource "fluxvale_access_gateway" "gateway" {
  tailnet_domain      = var.tailnet_domain
  api_token           = var.tailscale_api_token
  rotate_api_token_on = "2026-11-15" # bump whenever the token changes
  depends_on          = [fluxvale_custom_domain.apps]
}
```

One credential is enough (provider 0.6+): with `api_token` and no
`auth_key`, the platform **mints the gateway's join key from the
token** (single-use, tagged, revoked on use) and stores the token at
create, so nothing else is pasted and no join key ever changes hands.
Mint the token from a tailnet owner/admin account (console API tokens
carry that account's full permissions). `auth_key` remains the
documented fallback for paste-only setups: set one or the other, never
both. Your tailnet's ACL must own the `tag:fluxvale-gateway` tag or
the node cannot join.

The token save attempts to claim every verified domain. Read
`claimed_domains` for the result, and a later verification or attach claims
too. Bump `rotate_api_token_on` before the Tailscale key's 90-day
expiry. The attribute uses Terraform's write-only input support:
Terraform 1.12+ or OpenTofu 1.13+ and a provider release containing it.
Older CLIs can leave it out and paste the token in the panel.

### Read an existing instance

`fluxvale_instance` is also a data source, for an instance managed in another stack or outside Terraform:

```hcl
data "fluxvale_instance" "wiki" {
  slug         = "velvety-otter-1234"
  organization = "acme" # id or slug; optional when your token spans one org
}
```

Read by `id` (always unambiguous) or `slug`. A slug is unique only per cluster, so pass `organization` when your token spans several (it falls back to the provider-level `organization`). If a slug still matches more than one instance in one organization, the API answers `multiple_results`, so use the `id`. Your token's memberships decide what is visible, and an instance in another organization reads as not found.

### Wire PocketID sign-in

`fluxvale_pocket_id_sso` connects an instance's sign-in to your PocketID instance. One wiring per instance, and the resource's `id` is the instance id. The PocketID instance must be public and have held-key custody (its API key stored once), or the platform refuses the connect.

```hcl
resource "fluxvale_pocket_id_sso" "vault" {
  instance_id           = fluxvale_instance.vaultwarden.id
  pocket_id_instance_id = fluxvale_instance.pocket_id.id # a public PocketID instance in the same organization, with its API key stored (held-key custody)
  rotate_secret_on      = "2026-11-13"                  # bump to rotate the client secret in place
}
```

`rotate_secret_on` is a rotation trigger, not a replacement: changing it mints a second active secret, applies it to the workload, then deletes the old one once the workload patch is accepted. The client id and the resource id survive. The delete is best effort: a refused PocketID delete leaves the old secret active there, so check and remove it by hand. Pods still on the old value return 401 until the rollout cycles them. Changing `instance_id` or `pocket_id_instance_id` replaces the wiring (disconnect and a fresh client). The client secret's value never travels through Terraform, because the platform writes it into the instance's environment. Connect, disconnect, and rotate are gated by the platform's `pocketid_sso_wiring` flag (seeded enabled). The wiring read stays available while the flag is off.

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

- `versions.tf`: the registry source, the provider block, and a commented state-encryption block pointing at the OpenTofu state-encryption guide.
- `imports.tf`: one `import` block per live instance, backup setting, access gateway, and custom domain, plus commented blocks for PocketID SSO wirings (the provider does not implement `import` for them yet). Addresses come from slugs or names, with a numeric suffix when two sanitize to the same label. Import ids follow each resource's own shape: the instance id for instances, the instance id for backups and SSO, the org id or slug for the gateway, and the access-domain id for a domain.
- `README.md`: the three commands above plus the caveats below.

No resource bodies are rendered. `-generate-config-out` is the official, provider-schema-aware writer, because hand-rendered HCL would rot as the schema moves.

The MCP tool `terraform_import_bundle` returns the same three files (path and content) without writing anywhere. The CLI stamps its configured base URL into `versions.tf` when it differs from the provider's production default. The MCP tool leaves the provider on that default unless the caller passes `api_url` (for staging, pass `https://staging.fluxvale.com`, because the server's own upstream URL can be cluster-internal). It reads instances, backup settings, the access gateway, custom domains, and organizations, so its full scope set is `instances:read` + `backups:read` + `gateways:read` + `organizations:read`.

### Caveats

- **Write-only values are never readable back.** `generated.tf` cannot carry `env_vars` or a backup's `secret_access_key`. Re-add `env_vars` in your Terraform config from your own records after adoption (the provider writes them in place), and set the backup secret in the panel. The `enc:v1:` marker path in [ADR-0053](https://github.com/fluxvale/fluxvale/blob/main/docs/adr/00053-terraform-secret-env.md) is design-only, and the write-only `secret_env_vars` input is available from 0.4.0.
- **Generated config may need small edits before a clean plan.** `app`/`app_version` on an imported instance have no wire echo, the gateway's `instances` set is config-authoritative and starts null, and `rotate_secret_on` is config-only posture. Fill in what you want Terraform to manage, then re-plan.
- **Only user-owned domains are exported.** The org's system-minted `platform` access domain is skipped, because `fluxvale_custom_domain` manages `custom` rows.
- **PocketID SSO import is a provider gap.** The provider does not implement `import` for `fluxvale_pocket_id_sso` yet. The scaffold comments those blocks out, with the instance id as the import id. Uncomment them once the provider release you use supports import. Live `deleting` and `lost` instances are skipped for the same reason, since there is no remote object to adopt.
- **Gateway attachments are not discoverable.** The API has no attachment list, so `instances` stays null after import. Add the set by hand if Terraform should own it.

## Compatibility

The provider follows the platform's API, and 0.x may still adjust computed fields and add attributes. The published [compatibility notes](https://github.com/fluxvale/terraform-provider-fluxvale/blob/main/docs/guides/compatibility.md) state which names are stable from day one: the provider configuration, the `FLUXVALE_PAT` variable, and every resource and data source name listed above. Config you write against those names keeps working.

From 0.3.0, `env_vars` updates in place. It is write-only on the wire (never echoed) and remains a normal Terraform attribute, not a Terraform write-only attribute. Plaintext values still live in state.

`secret_env_vars`, `secret_env_vars_version`, and the computed `secret_env_vars_keys` are additive: existing configurations need no change. The new attributes require Terraform 1.12+ or OpenTofu 1.13+ and provider 0.4.0+. On an older CLI, leave them out and use `env_vars` plus state encryption at rest.
