---
title: Custom domains
description: Bring your own domain for your private apps, verified by certificate issuance over DNS.
order: 20
slug: custom-domains
---

Every app gets an address under `fluxvale.app` for free. You can also bring your own domain. Custom domains are aimed at the private-access lane, where your apps are reachable only from your own network.

Custom domains are free of charge. Registering one requires a one-time top-up of at least $1 in your organization's wallet, like the other infrastructure features.

## How verification works

You register a domain such as `apps.example.com`. The platform then proves control of it the honest way, by issuing a wildcard certificate for `*.apps.example.com` through the public ACME DNS-01 challenge. No certificate, no verified domain.

Two DNS records at your provider make this work:

1. A **CNAME** for the hostname prefix you will use.
2. A **CNAME for `_acme-challenge`** under the domain, delegating the certificate challenge into a FluxVale zone, so certificates issue and renew without you handing over DNS credentials.

The platform never holds your DNS credentials. You keep full control of the zone.

Verification runs on a regular pass with a cadence of about 15 minutes, so allow time after your records are in place. If issuance does not succeed within its window, about 72 hours, the registration is marked failed and you register the domain again.

## Where the feature is today

Registration is available through the API and the Terraform provider. The [Terraform guide](/docs/automation/terraform) shows a working example with the `fluxvale_custom_domain` resource, including how to wait out verification. If you are setting a domain up today, write to [support@fluxvale.com](mailto:support@fluxvale.com) and we will walk you through the records.

One honest caveat. A verified domain proves the certificate and its wildcard. Wiring the domain's names to answer on your private network is the remaining half of the feature and is still being built. Today the working private-access setup uses the gateway's own hostname on your tailnet, which you will find in the access tab of your organization's settings.

The DNS records you create now are the ones the finished feature will use. No re-registration will be needed.
