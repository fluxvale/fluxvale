---
title: Terraform provider
description: Manage FluxVale apps, backups, gateways, and domains as infrastructure code.
order: 20
slug: terraform
---

The FluxVale provider manages your apps with Terraform or OpenTofu. It covers the same ground as the panel: instances, backups, private-access gateways, and custom domains.

The provider is on the public registry at [registry.terraform.io/fluxvale/fluxvale](https://registry.terraform.io/providers/fluxvale/fluxvale/latest). Declare it under Configure and run `terraform init` — or `tofu init`: OpenTofu honors the explicit `registry.terraform.io` source the same way, signed downloads included.

## Install the provider

The provider's source and releases live in [fluxvale/terraform-provider-fluxvale](https://github.com/fluxvale/terraform-provider-fluxvale).

There is no manual install step. The `required_providers` block under Configure names the registry source, and `terraform init` or `tofu init` pulls the signed provider from it.

Offline and air-gapped machines cannot reach the registry. For those, mirror a release archive locally and point the tool at it:

1. Download the zip for your platform from the [releases page](https://github.com/fluxvale/terraform-provider-fluxvale/releases) — adjust the file names below to the platform and version you took — together with the versioned checksums `terraform-provider-fluxvale_0.2.1_SHA256SUMS`. Verify the archive:

   ```sh
   grep terraform-provider-fluxvale_0.2.1_linux_amd64.zip terraform-provider-fluxvale_0.2.1_SHA256SUMS | sha256sum -c -   # macOS: shasum -a 256 -c -
   ```

2. Create the mirror tree and place the zip:

   ```sh
   mkdir -p ~/.tfplugins-mirror/registry.terraform.io/fluxvale/fluxvale
   cp terraform-provider-fluxvale_0.2.1_linux_amd64.zip ~/.tfplugins-mirror/registry.terraform.io/fluxvale/fluxvale/
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
      version = "~> 0.2"
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
- Data sources `fluxvale_apps` and `fluxvale_app_versions` read the catalog.

The worked example in the provider's repository, under [`examples/personal-stack`](https://github.com/fluxvale/terraform-provider-fluxvale/tree/main/examples/personal-stack), composes all of them into one stack.

## Compatibility

The provider follows the platform's API, and 0.x may still adjust computed fields and add attributes. The published [compatibility notes](https://github.com/fluxvale/terraform-provider-fluxvale/blob/main/docs/guides/compatibility.md) state which names are stable from day one: the provider configuration, the `FLUXVALE_PAT` variable, and every resource and data source name listed above. Config you write against those names keeps working.
