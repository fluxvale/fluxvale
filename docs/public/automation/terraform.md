---
title: Terraform provider
description: Manage FluxVale apps, backups, gateways, and domains as infrastructure code.
order: 20
slug: terraform
---

The FluxVale provider manages your apps with Terraform or OpenTofu. It covers the same ground as the panel: instances, backups, private-access gateways, and custom domains.

The provider is not on the public registry yet. You install it from a release archive into a local filesystem mirror, and the usual Terraform flow takes over from there.

## Install the provider

1. Download the zip for your platform from the releases page, tagged `tf-v*`, together with `SHA256SUMS`. Verify the archive:

   ```sh
   grep terraform-provider-fluxvale_0.1.0_linux_amd64.zip SHA256SUMS | sha256sum -c -
   ```

2. Place the zip in a local mirror:

   ```
   ~/.tfplugins-mirror/
     registry.terraform.io/fluxvale/fluxvale/terraform-provider-fluxvale_0.1.0_linux_amd64.zip
   ```

3. Point Terraform at the mirror in `~/.terraformrc`, or `~/.tofurc` for OpenTofu:

   ```hcl
   provider_installation {
     filesystem_mirror {
       path    = "/home/you/.tfplugins-mirror"
       include = ["registry.terraform.io/fluxvale/fluxvale"]
     }
     direct {}
   }
   ```

## Configure

```hcl
terraform {
  required_providers {
    fluxvale = {
      source = "registry.terraform.io/fluxvale/fluxvale"
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

The full resource set:

- `fluxvale_instance` deploys an app, with allocation, environment inputs, run state, and exposure.
- `fluxvale_instance_backups` sends backups to your own S3-compatible bucket.
- `fluxvale_access_gateway` runs the private-access gateway for your organization.
- `fluxvale_custom_domain` registers your own domain on the private edge. See the [custom domains guide](/docs/guides/custom-domains) for what verification means.
- Data sources `fluxvale_apps` and `fluxvale_app_versions` read the catalog.

The worked example in the provider's repository, under `examples/personal-stack`, composes all of them into one stack.

## Compatibility

The provider follows the platform's API, and 0.x may still adjust computed fields and add attributes. The published [compatibility notes](https://github.com/fluxvale/fluxvale/blob/main/apps/tfprovider/docs/compatibility.md) state which names are stable from day one: the provider configuration, the `FLUXVALE_PAT` variable, and every resource and data source name listed above. Config you write against those names keeps working.
