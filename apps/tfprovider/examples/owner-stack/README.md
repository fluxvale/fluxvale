# The owner stack (one root module)

The owner's personal production stack, codified: one R2 bucket
feeding every instance's backups, the tailnet access gateway for the
private instances, and the instances tying it together — the #482
rider. This is a **skeleton**: placeholder variables only, nothing
real in git, nothing applies until the owner fills in
`terraform.tfvars` and runs it himself. The pairing step below is the
checklist for exactly that.

The single-instance teaching example with explicit resource pairs
lives next door in
[examples/personal-stack](../personal-stack/README.md).

## What it stands up

- **1 R2 bucket** (cloudflare provider) — every instance's backups
  land in it under its own prefix (`fluxvale/<name>/`).
- **3 instances** (`var.instances`, keyed by name) — defaults are
  three representative shapes: a public always-on forgejo, memos and
  kavita private behind the gateway.
- **1 backups row per instance** — endpoint composed from the
  Cloudflare account id, bucket from the TF-created bucket, per
  instance prefix and retention.
- **The access gateway** — joins the tailnet, attaches every
  `exposure = "private"` instance (the attach waits for the gateway
  to become active).
- **Custom domains per instance** (`var.instances.<name>.domain`) —
  set a domain and it registers on the private-access edge. The
  dogfood pairings — forgejo → `git.fluxvale.com`, umami →
  `analytics.fluxvale.com` — ride as documented placeholder rows,
  pending the dogfood plan (which owns the domain/OIDC/money-gate
  decisions); the defaults register nothing.

The dependency graph IS the apply order: bucket + gateway create +
instances first, then backups rows and the attach calls. One
`tofu apply` handles it; there is no manual ordering.

## The pairing checklist — what Terence brings

| Value | Where it comes from | Goes where |
| --- | --- | --- |
| `FLUXVALE_PAT` | fluxvale.com → Settings → Developer → API tokens (scopes: `instances:write backups:write gateways:write catalog:read`) | `export FLUXVALE_PAT=fvpat_…` — **only** the environment, never a file, never pasted into the repo or notes |
| `cloudflare_api_token` | Cloudflare dashboard → API tokens (R2 edit on the account) | `terraform.tfvars` |
| `cloudflare_account_id` | Cloudflare dashboard → account overview | `terraform.tfvars` |
| `r2_access_key_id` / `r2_secret_access_key` | Cloudflare dashboard → R2 → Manage API Tokens (object read/write) | `terraform.tfvars` |
| `r2_bucket_name` | decision — default `fluxvale-backups`, unique in the account | optional, `terraform.tfvars` |
| `tailnet_domain` | Tailscale admin console — the MagicDNS suffix (`<tailnet>.ts.net`) | `terraform.tfvars` |
| `tailscale_auth_key` | Tailscale admin console → Settings → Keys (an auth key that can enroll a device) | `terraform.tfvars` |
| `instances` | the catalog (listing one-liner below) + app/version/size choices | optional, `terraform.tfvars` |
| `instances[].domain` | the dogfood plan — `git.fluxvale.com` (forgejo) and `analytics.fluxvale.com` (umami) are the placeholder pairings | optional, `terraform.tfvars` — left unset until that plan lands |

The token scopes match the workflow's acceptance preflight
(`.github/workflows/tfprovider-acceptance.yml`); mint once, reuse.

To see the catalog while picking apps:

```sh
tofu console
> [for a in data.fluxvale_apps.catalog.apps : a.slug]
> [for v in data.fluxvale_app_versions.all["memos"].app_versions : v.version]
```

## Install the providers (once)

This module composes two providers, so it needs the
[filesystem mirror](../../docs/install.md) setup — `dev_overrides`
alone cannot get you there, because `tofu init` still queries the
registry for the unpublished fluxvale provider and refuses to install
cloudflare. Two cases:

- **Release zips exist** (GitHub Releases, tag `tf-v*`): follow
  docs/install.md §1–3 — download the zip + `SHA256SUMS`, verify,
  drop into `~/.tfplugins-mirror`, point `~/.tofurc` at it.
- **They don't yet** (the `tf-v0.1.0` run failed before attaching
  assets): build and zip the provider yourself — `cd apps/tfprovider
  && go build -o /tmp/terraform-provider-fluxvale_v0.1.0 .` then zip
  that binary and lay it out per docs/install.md §2. A re-release
  makes this paragraph obsolete.

## Run and verify

```sh
cd apps/tfprovider/examples/owner-stack
cp terraform.tfvars.example terraform.tfvars   # then fill it in
export FLUXVALE_PAT=fvpat_…                    # never in a file
tofu init                                      # mirror + registry (cloudflare)
tofu plan
tofu apply
tofu output
```

Rehearse against staging first if wanted: `api_url =
"https://staging.fluxvale.com"` plus a staging PAT in the env.

Verified when:

- `tofu plan` shows 1 bucket, N instances, N backup rows, the
  gateway (or an adoption import — see below), nothing unexpected.
- `tofu apply` completes; `tofu output` prints the public URLs and
  the gateway host.
- The panel shows the instances running, backups rows enabled, and
  the Access tab shows the gateway active with the private instances
  attached.
- From a device on the tailnet, the private instances answer through
  the gateway.

Two honest caveats: **the gateway is an org singleton that bills
monthly and has no API delete** — destroy removes it from state only;
opt out via the panel's Access tab (adopt an existing one with
`terraform import fluxvale_access_gateway.owner <org_id_or_slug>`).
And **backups need the org to have paid once** — a 403 on the first
backups save is the wallet, not a bug.

## Deliberately not decided here

The custom-domain resource IS composed (per-instance `domain`
attribute) — what's pending is the dogfood initiative's decisions
(domains, OIDC, money gates; a separate lane). Until it lands the
pairings stay placeholder rows: no domain registers on apply. Two
known platform facts for that conversation: the first
`fluxvale_custom_domain` create passes the org-wallet gate
(`ActorOrgHasPaid`), and `verified` is NOT resolution — the
split-DNS claim has no API surface yet
([examples/personal-stack](../personal-stack/README.md) documents
both).
