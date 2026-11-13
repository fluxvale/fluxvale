---
title: Single sign-on with Pocket ID
description: One passkey identity for your apps, with the Pocket ID and Forgejo wiring verified end to end.
order: 50
slug: sso
---

Pocket ID is the identity app in the catalog. Deploy it, claim it, add a passkey, and your other apps hand their sign-in to it over OpenID Connect. This page is the shared setup plus the full Pocket ID + Forgejo recipe, verified against a live stack. The other apps' fields and callbacks are in the [sign-in with Pocket ID guide](https://fluxvale.com/guides/sign-in-with-pocket-id).

## What it covers

One identity, one passkey, across your apps. No password reuse, no per-app credential sprawl. Pocket ID speaks OpenID Connect, which most self-hosted apps understand natively.

Six catalog apps consume it today: Forgejo, Kavita, Vaultwarden, ActualBudget, Memos, and Vikunja. Umami is not one of them. The self-hosted Umami in the catalog has no OIDC client; SSO is an Umami Cloud feature.

## Before you wire an app

### Deploy Pocket ID first

Deploy Pocket ID before the apps that will use it. Keep the instance public. The apps' servers fetch tokens from it directly, so the issuer URL has to work from their containers, not only in your browser.

Turn on **Always on** on the instance page after deploy. An identity instance that sleeps fails the first sign-in after a wake, and the apps that point at it fail with it. Always-on bills its running rate around the clock, so size it small.

### Keep a second passkey outside it

Add a second passkey from a device that does not depend on Pocket ID, such as a phone or a hardware key. If the only passkey lives in an app whose sign-in goes through Pocket ID, one lost device or one broken instance locks you out of both.

### Create the user, then the client

In Pocket ID open **Administration**, then **Users**, and create one user per person.

A new user has no passkey yet. In Pocket ID, open the user's **⋯** menu, choose **Login Code**, and click **Show Code**. The code is one-time, so send it to that person only. The user opens **Alternative Sign In Methods**, then **Login Code**, enters the code, and adds a passkey. Do this before the Forgejo sign-in step.

Then open **Administration**, then **OIDC Clients**, then **Add OIDC Client**. Name the client `Forgejo` and set the callback to:

```
https://<forgejo-host>/user/oauth2/PocketID/callback
```

The `PocketID` segment is the Forgejo authentication source name. Name the source `PocketID`, or change the callback to match. Other apps use the same shape with their own name and callback. The client page shows the client ID, the client secret, and the discovery URL. Copy the secret when you create the client. Pocket ID shows it once; if you lose it, rotate the secret or recreate the client.

### Unrestrict the client

A new client starts restricted to **Selected user groups** with no groups selected. **All Users** is not the default, even though it looks like the obvious choice. The first sign-in then fails inside Pocket ID with:

```
You are not allowed to access this service.
```

Open the client's **Access** tab and choose **Unrestrict**, then **All Users**. The dialog says the change removes all group assignments for the client and lets any user sign in. Do this for every client that should be open to everyone.

## Forgejo end to end

Verified with Pocket ID 2.19.2 and Forgejo 16.0.5.

### Add the authentication source

In Forgejo open **Site Administration**, then **Identity & Access**, then **Authentication Sources**, then **Add OAuth2**, and choose **OpenID Connect**.

Set:

- **Name**: `PocketID`. This name is part of the callback path.
- **Discovery URL**: the one on the Pocket ID client page, ending in `/.well-known/openid-configuration`.
- **Client ID** and **Client secret**: from the same client page.
- **Additional scopes**: `openid email profile`.
- Tick **This authentication source is activated**.

Save. The source appears in the list, marked active.

### Create the Forgejo user first

Forgejo 16.0.5 has no auto-registration control on the authentication-source form. Its global `[oauth2_client] ENABLE_AUTO_REGISTRATION` setting defaults to `false`, so Forgejo does not create an account for an unknown Pocket ID user. That user lands on `/user/link_account` instead of the dashboard. With registration disabled, that page cannot create the account either.

If the person already has a Forgejo account, do not create a second one. On first sign-in with the `PocketID` source, Forgejo shows the account-linking page at `/user/link_account`. Sign in there with the existing username and password to link the accounts.

If the person has no Forgejo account, pre-create one. In **Site Administration**, then **Users**, create the account, then:

- Set **Authentication source** to `PocketID`.
- Set **Authentication sign-in name** to the Pocket ID user's `sub`, the UUID shown on their user page in Pocket ID. It is not the email.
- Use the same email address as Pocket ID.

The first passkey sign-in then matches that account and lands on the dashboard.

If you want self-service onboarding, the only lever is the global `[oauth2_client] ENABLE_AUTO_REGISTRATION` setting. Turn it on and any Pocket ID user this client admits gets a Forgejo account. This recipe stays on the default and pre-creates users who do not have an account.

### Sign in

On Forgejo's sign-in page choose the `PocketID` source and approve with the passkey. The first sign-in lands on `/` as that user, and later sign-ins take the same path.

### The local admin still works

The local admin account keeps working after the OAuth2 source is active. Sign in with its username and password on Forgejo's own form, and keep it as the recovery path.

## Wire your other apps

Five other catalog apps consume Pocket ID: Kavita, Vaultwarden, ActualBudget, Memos, and Vikunja. Their callback paths and exact fields are in the [sign-in with Pocket ID guide](https://fluxvale.com/guides/sign-in-with-pocket-id).

The Pocket ID side is the same for every app: create the client with the app's callback, then unrestrict it if everyone should sign in. The app side differs.

## If Pocket ID goes down

Connected apps degrade, they do not die. Already-signed-in sessions persist. New sign-ins fail while the issuer is unreachable and come back when it is reachable again.

Keep one local way in per app. Forgejo's local admin is the one verified here; the other apps' recovery notes are in the [sign-in guide](https://fluxvale.com/guides/sign-in-with-pocket-id).

Destroying Pocket ID is permanent. The destroy deletes the instance and its data, so the identities it holds are lost unless you can restore from a backup you own. A restore needs both the backup password and the Pocket ID `ENCRYPTION_KEY` from deploy time. Save both before you destroy anything. The [backups guide](/docs/guides/backups) covers the backup password; it does not carry the encryption key.
