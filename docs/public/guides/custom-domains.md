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

Two DNS records at your provider make this work:

1. A **CNAME** for the hostname prefix you will use.
2. A **CNAME for `_acme-challenge`** under the domain, delegating the certificate challenge into a FluxVale zone, so certificates issue and renew without you handing over DNS credentials.

The platform never holds your DNS credentials. You keep full control of the zone.

Verification runs on a regular pass with a cadence of about 15 minutes, so allow time after your records are in place. If issuance does not succeed within its window, about 72 hours, the registration is marked failed and you register the domain again.

## Where the feature is today

Registration is available through the API and the Terraform provider. The [Terraform guide](/docs/automation/terraform) shows a working example with the `fluxvale_custom_domain` resource, including how to wait out verification. If you are setting a domain up today, write to [support@fluxvale.com](mailto:support@fluxvale.com) and we will walk you through the records.

The mint is live. Once a custom domain is verified, add an address on the instance page: **Custom addresses** takes a label such as `git` and mints `git.<your-domain>`. The member API carries the same three verbs, `POST`/`GET /api/v1/instances/:instance_id/hostnames` and `DELETE /api/v1/instance-hostnames/:id`.

A custom address serves only when all three are true: the domain is verified, your organization's gateway has claimed it, and the instance is private and attached to that gateway. Claiming is one paste: in **Settings → Access**, add a Tailscale API token with the `dns`, `devices:routes`, `devices:core:read` and `auth_keys` scopes. The token is stored write-only and never shown again, and saving it claims every domain your organization has already verified. The member API carries the same write: `PATCH /api/v1/access-gateways/:id/api-token`. Tailscale API keys expire within 90 days, so paste a fresh one before then. Until the three conditions hold, the address is recorded and serves nothing yet. The certificate and the DNS records do not change — the wildcard you verified covers every label you mint under it.

The DNS records you create now are the ones the finished feature will use. No re-registration will be needed.
