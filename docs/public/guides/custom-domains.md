---
title: Custom domains
description: Bring your own domain for your private apps, verified by certificate issuance over DNS.
order: 20
slug: custom-domains
---

Every app gets an address under `fluxvale.app` for free. You can also bring your own domain. Custom domains are aimed at the private-access lane, where your apps are reachable only from your own network.

Custom domains are free of charge. Registering one requires a one-time top-up of at least $5 in your organization's wallet, like the other infrastructure features.

## How verification works

You register a domain such as `apps.example.com`. The platform then proves control of it the honest way, by issuing a wildcard certificate for `*.apps.example.com` through the public ACME DNS-01 challenge. No certificate, no verified domain.

One DNS record at your provider makes this work:

```
_acme-challenge.apps.example.com  CNAME  <target>.acme.fluxvale.app
```

The target is per-domain and stable. Get it from the platform API (`GET /api/v1/domain-delegations/apps.example.com`), or from the `fluxvale_domain_delegation` data source in Terraform:

```hcl
data "fluxvale_domain_delegation" "apps" {
  domain = "apps.example.com"
}
```

The platform writes the ACME TXT record in its own validation namespace, so certificates issue and renew without you handing over DNS credentials. Its cert-manager DNS-01 solver runs with `cnameStrategy: Follow` under `dns01`, which follows your CNAME into that namespace; without it the challenge would be written in your zone and fail. You keep full control of the zone.

Three things matter at your DNS provider:

- **Create the `_acme-challenge` record explicitly.** A wildcard CNAME in your zone can synthesize one and break the delegation.
- **A DNSSEC-signed zone must sign the delegation CNAME.** If issuance fails, this is the likely cause.
- **No host record is needed.** Your app's name resolves only through your tailnet after the gateway claims the domain; there is no public address to point a host CNAME at.

### Cloudflare in Terraform

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

The example targets Cloudflare provider v5. On v4 the record resource is `cloudflare_record` and the zone data source takes `name` directly instead of `filter`; the record fields are otherwise the same.

Verification runs on a regular pass with a cadence of about 15 minutes, so allow time after your records are in place. If issuance does not succeed within its window, about 72 hours, the registration is marked failed. Remove the failed registration, then register the domain again — platform-wide uniqueness refuses a same-name re-register while the row stands.

## Verification is not resolution

`verified` means the wildcard certificate issued. The name still answers nothing until your organization's gateway claims the domain. Saving the gateway's Tailscale API token claims the verified domains it can; a later verification or an instance attach claims too. With the provider, the token save joins the apply that creates the gateway or bumps `rotate_api_token_on` — order the gateway after the domain. Off tailnet the name does not resolve.

## Where the feature is today

Registration is available through the API and the Terraform provider. The [Terraform guide](/docs/automation/terraform) shows a working example with the `fluxvale_custom_domain` resource, the delegation data source, and the gateway token, including how to wait out verification.

The mint is live. Once a custom domain is verified, add an address on the instance page: **Custom addresses** takes a label such as `git` and mints `git.<your-domain>`. The member API carries the same three verbs, `POST`/`GET /api/v1/instances/:instance_id/hostnames` and `DELETE /api/v1/instance-hostnames/:id`.

A custom address serves only when all three are true: the domain is verified, your organization's gateway has claimed it, and the instance is private and attached to that gateway.

Claiming is one token save. In **Settings → Access**, paste a Tailscale API access token from your admin console's Keys page, or set `api_token` on the Terraform gateway.

One credential is enough: enabling with the token alone (no auth key) makes the platform **mint the gateway's join key from it** — single-use, tagged, revoked on use — so you never mint or paste a join key yourself. Mint the token from a tailnet owner or admin account: console API tokens carry that account's full permissions (scope selection belongs to trust credentials — OAuth clients — not Keys-page tokens). The token is stored write-only and never shown again. The save attempts to claim every verified domain your organization has; read `claimed_domains` for the result. The member API carries the same writes: the create (`POST /api/v1/access-gateways`, one credential or the other) and the token save (`PATCH /api/v1/access-gateways/:id/api-token`).

Tailscale API keys expire within 90 days, so save a fresh one before then. In Terraform, bump `rotate_api_token_on` to re-send it. Until the three conditions hold, the address is recorded and serves nothing yet. The certificate and the DNS records do not change — the wildcard you verified covers every label you mint under it.

Remove the `_acme-challenge` CNAME when you remove the domain. A delegation left behind is a takeover path for that hostname.
