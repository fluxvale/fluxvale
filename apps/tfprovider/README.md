# FluxVale Terraform/OpenTofu provider

A thin skin over the FluxVale JSON:API (`/api/v1`, PAT auth) —
[ADR-0019](../../docs/adr/00019-machine-first-api-cli-mcp.md) Am. 4.
Policy, paywall, and scopes enforce server-side; the provider
re-implements nothing.

**Status**: first resource + data sources (#482 P4) on the scaffold
(#482 P3). The v0 resource set is named in the
[compatibility contract](docs/compatibility.md); the instance family's
remaining resources (backups, access gateway, custom domain) land in
follow-up slices.

## Resources and data sources

- `fluxvale_instance` — deploys a catalog app version. The version and
  allocation (`cpu_cores`/`memory_mb`/`storage_gb`), the name, the
  organization, and `env_vars` are create-only (the API has no
  rename/resize/version-change routes), so changing them replaces the
  instance. `running`/`always_on`/`exposure` update in place via their
  PATCH verbs.
  - `env_vars` is write-only: the API never echoes it, so plan can't
    see server-side drift by design, and the configured value is kept
    verbatim in state.
  - `organization` (id or slug) falls back to the provider-level
    `organization`, then to your sole organization — several
    memberships without a name is an error, never a silent pick.
  - Import: `terraform import fluxvale_instance.x <id>`. Attributes the
    API does not echo (`organization`, `app`, `app_version`,
    `app_version_id`, `env_vars`) stay null after import — keep your
    config matching what you deployed, or plan shows a replacement.
- `fluxvale_apps` — the catalog. `fluxvale_app_versions` — one app's
  versions, by `app` (slug) or `app_id`.

The provider is a skin: business rules (paywall, scopes, allocation
bounds) enforce server-side — a 422 is the correct error surface.

## Authentication

The provider needs a FluxVale personal access token (`fvpat_…`):

- `token` attribute in the provider block, or
- the `FLUXVALE_PAT` environment variable (preferred — no secrets in
  code; placeholders only in `.tf` files).

Configure pings `/api/v1/me` (scopeless — any live token works), so a
dead token fails at plan time with the server's wording.

## Dev loop (dev_overrides)

The registry isn't live yet; use [dev_overrides](https://developer.hashicorp.com/terraform/plugin/debug-vendor):

```sh
cd apps/tfprovider && go build -o ~/.tfplugins/terraform-provider-fluxvale .
```

`~/.terraformrc` (OpenTofu: `~/.tofurc`):

```hcl
provider_installation {
  dev_overrides {
    "registry.terraform.io/fluxvale/fluxvale" = "/home/you/.tfplugins"
  }
  direct {}
}
```

Then point a config at the provider — no `terraform init` needed:

```hcl
terraform {
  required_providers {
    fluxvale = { source = "registry.terraform.io/fluxvale/fluxvale" }
  }
}

provider "fluxvale" {
  # api_url = "https://staging.fluxvale.com"  # staging override
}
```

Or run it debugger-attached: `go run . -debug` and follow the printed
`TF_REATTACH_PROVIDERS` export.

## CI

Path-gated lane in `.github/workflows/ci.yml` (`tfprovider`): gofmt +
vet + test + build, Go version parsed from the root `mise.toml` pin.
