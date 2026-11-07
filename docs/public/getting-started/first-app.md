---
title: Create your first app
description: Deploy an app from the catalog, pick its resources, and open it on its own address.
order: 20
slug: first-app
---

Deploying an app on FluxVale takes a few clicks. This page walks through the whole flow.

## Pick an app

Open the [catalog](https://fluxvale.com/catalog) and browse the apps. Each catalog page shows what the app does, its source and docs links, and what it costs per month at its default size.

The catalog today covers Forgejo, Kavita, Memos, Vaultwarden, Pocket ID, and ActualBudget.

## Deploy it

Press **Deploy** on the app's page. The deploy form has four steps:

1. **Version.** Pick the release you want. Usually the newest.
2. **Configuration.** Some apps ask for settings at deploy time, such as an encryption key or single sign-on details. If the app has none, the step says so.
3. **Resources.** Choose how much CPU, memory, and storage the app gets. Quick picks set a sensible size in one press, or drag the sliders yourself. Going below the app's recommendation shows a warning, and you can acknowledge it and continue anyway.
4. **Name.** Give the instance a name for your own reference. The platform generates the address, and you can rename the instance later.

Press **Deploy** and the status page tracks the rollout. It updates on its own. When the app is up, the page shows its address.

## Open it

Every app gets an address like `something.fluxvale.app`. Open it from the instance page with the **Open** button.

Some apps need a first-run step, such as creating the administrator account on your first visit. The instance page shows the app's first-run guidance before the button, so read it on your first deploy.

## Sleeping and waking

Apps sleep after an hour without visitors and wake on the next visit. The waking page usually clears in seconds and refreshes itself. While an app sleeps you pay only for its storage.

If you would rather an app never sleeps, turn on **Always on** on its instance page. An always-on app bills its running rate around the clock. Identity apps you depend on, such as Pocket ID, are good candidates.

## Next

- [Sizes and compute classes](/docs/guides/sizes) explains the resource axis and billing.
- [Backups](/docs/guides/backups) protects the app's data.
- The [CLI quickstart](/docs/automation/cli) does all of this from the terminal.
