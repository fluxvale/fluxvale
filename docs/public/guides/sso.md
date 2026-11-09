---
title: Single sign-on with Pocket ID
description: One passkey identity for your app suite, wired app by app with Pocket ID.
order: 50
slug: sso
---

Pocket ID is the identity app in the catalog. Deploy it, claim it, add a passkey, and your other apps can hand their sign-in to it over OpenID Connect.

## What it gives you

One identity, one passkey, across your apps. No password reuse, no per-app credential sprawl. Pocket ID speaks OpenID Connect, which most self-hosted apps understand natively.

Six catalog apps consume it today: Forgejo, Kavita, Vaultwarden, ActualBudget, Memos, and Vikunja.

## Deploy it first

Deploy Pocket ID from the [catalog](https://fluxvale.com/catalog) before the apps that will use it. Keep the instance public, because the other apps' servers fetch tokens from it directly. The issuer URL has to work from their containers, not only in your browser.

Run it always-on. If the identity instance sleeps, the first sign-in after a wake can fail. Turn on **Always on** on the instance page after deploy. An always-on instance bills its running rate around the clock, so size it small.

## Wire your apps

Create one OIDC client per app in Pocket ID, then wire each app with its client ID and secret:

- Some apps, such as Vaultwarden, ActualBudget, and Vikunja, take the provider settings on the deploy form.
- Others, such as Forgejo, Kavita, and Memos, are configured inside the app after deploy.

The full wiring walkthrough, with every app's callback path and the exact fields, lives in the [sign-in with Pocket ID guide](https://fluxvale.com/guides/sign-in-with-pocket-id).

## If Pocket ID goes down

Connected apps degrade, they do not die. Already-signed-in sessions persist. New sign-ins fail while the issuer is unreachable and come back when it is reachable again.

Keep one local way in per app. And keep the Pocket ID instance backed up. Destroying it loses the identities it holds, unless you can restore from a backup you own. The [backups guide](/docs/guides/backups) covers the setup, including the backup password you will want to have saved.
