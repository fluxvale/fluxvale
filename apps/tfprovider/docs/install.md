# Installing the provider

Manual-first ([ADR-0019](../../../docs/adr/00019-machine-first-api-cli-mcp.md)
Am. 4): the registry isn't live yet, so the provider installs from
GitHub Releases into a local filesystem mirror — or, for dev work,
straight off a freshly built binary via `dev_overrides`.

## 1. Download a release

Grab the zip for your platform from the repo's
[Releases](https://github.com/fluxvale/fluxvale/releases) (tag `tf-v*`)
plus `SHA256SUMS`, and verify before use:

```sh
sha256sum -c SHA256SUMS   # run in the download directory
```

## 2. Lay out the filesystem mirror

The registry's own layout, with the downloaded zips dropped in
unchanged (the `<os>_<arch>` names are the registry's vocabulary):

```
~/.tfplugins-mirror/
  registry.terraform.io/
    fluxvale/
      fluxvale/
        0.1.0/                       # the release version
          linux_amd64.zip
          linux_arm64.zip
          darwin_arm64.zip
          windows_amd64.zip
```

## 3. Point the CLI at it

`~/.tofurc` (Terraform: `~/.terraformrc`):

```hcl
provider_installation {
  filesystem_mirror {
    path    = "/home/you/.tfplugins-mirror"  # placeholder — your mirror dir
    include = ["registry.terraform.io/fluxvale/fluxvale"]
  }
  direct {}
}
```

A config that declares the provider then plans without any registry
contact:

```hcl
terraform {
  required_providers {
    fluxvale = {
      source = "registry.terraform.io/fluxvale/fluxvale"
    }
  }
}

provider "fluxvale" {
  # api_url = "https://staging.fluxvale.com"  # staging override
  # token not set here — FLUXVALE_PAT is preferred (no secrets in code)
}
```

Upgrade = download the new version's zips into the mirror and bump the
required version in your config; both versions can sit side by side.

## Dev loop (dev_overrides)

Working on the provider itself — no mirror, no release needed:

```sh
cd apps/tfprovider && go build -o ~/.tfplugins/terraform-provider-fluxvale .
```

```hcl
provider_installation {
  dev_overrides {
    "registry.terraform.io/fluxvale/fluxvale" = "/home/you/.tfplugins"
  }
  direct {}
}
```

No `init` required; rebuild + re-run. See the README's dev-loop section
for the debugger-attached variant (`go run . -debug`).

## The registry, later

The eventual switch is a dedicated registry repository with GPG-signed
releases — deferred until there are users beyond the owner (the
compatibility contract in [compatibility.md](compatibility.md) is what
makes that switch non-breaking).
