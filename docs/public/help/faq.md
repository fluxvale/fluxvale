---
title: FAQ and getting help
description: Common questions about FluxVale, and where to reach us.
order: 10
slug: faq
---

## Frequently asked questions

**How do I get an account?**
FluxVale runs invitation-only early access. Write to [support@fluxvale.com](mailto:support@fluxvale.com) and we will send an invite. The [invites guide](/docs/guides/invites) has the details.

**Is there a free tier?**
There is no tier list. New accounts start with a small welcome credit. After that you top up your wallet and everything bills hourly against it. The [pricing calculator](https://fluxvale.com/pricing) shows what an app costs at any allocation.

**What happens when my wallet runs empty?**
Apps stop when the balance reaches zero. Data is kept for 30 days, with reminder emails at 7 days and 1 day before deletion. Top up and the apps start again.

**Do my apps run all the time?**
Apps sleep after an hour without visitors and wake on the next visit, usually in seconds. You pay only storage while one sleeps. Turn on always-on for an app that must never sleep.

**Where does my data live?**
In the cluster, in your app's own volume, and in your own backup bucket if you set one up. The platform takes no platform-side copies of your app data. The [backups guide](/docs/guides/backups) explains the honest version of this.

**Can I use my own domain?**
Yes, on the private-access lane, verified by certificate issuance. The [custom domains guide](/docs/guides/custom-domains) says where the feature stands today. The default `fluxvale.app` address is free.

**Can I export my data and leave?**
Yes. The apps are open-source and their formats are yours. Backups land in your own bucket in standard restic format, so the data leaves with you. Apps that declare file access, Kavita today, also expose their volume over WebDAV for copying files out directly.

**Is there an API?**
Yes, a JSON:API surface with personal access tokens, plus the [CLI](/docs/automation/cli), the [Terraform provider](/docs/automation/terraform), and an MCP endpoint for agents.

**Which regions are available?**
One region today, in Nuremberg. The architecture is built so more can follow.

## Getting help

- **Product support:** [support@fluxvale.com](mailto:support@fluxvale.com). A human reads it.
- **Feedback and feature requests:** the public [feedback board](https://fluxvale.com/feedback). Paying customers can post, everyone can read and follow.
- **The roadmap:** public at [fluxvale.com/roadmap](https://fluxvale.com/roadmap), updated as work ships.
- **Legal and privacy notices:** [admin@fluxvale.com](mailto:admin@fluxvale.com).

Policies live under [fluxvale.com/policies](https://fluxvale.com/policies/terms): terms, acceptable use, refunds, and privacy.
