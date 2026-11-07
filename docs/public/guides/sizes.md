---
title: Sizes and compute classes
description: Compute classes pick CPU and memory. Storage is a separate axis with per-app defaults.
order: 10
slug: sizes
---

An app on FluxVale runs with an allocation of CPU, memory, and storage. Two of those come as a bundle. The third is separate on purpose.

## Compute classes

A size is a compute class: a pairing of CPU and memory. These are the classes:

| Class | CPU | Memory |
| --- | --- | --- |
| micro | 0.25 | 512 MB |
| small | 0.5 | 512 MB |
| medium | 0.5 | 1 GB |
| standard | 1 | 2 GB |
| plus | 2 | 4 GB |
| pro | 4 | 8 GB |

The deploy form's quick picks are these classes. The cheapest class starts at $2.59 per month.

You are not limited to the classes. The sliders let you allocate any combination of the offered CPU and memory rungs, above or below the class table. Each app version carries a recommendation, and the deploy form warns you when you go under it.

Resizing an app later happens on its instance page. CPU and memory go both up and down. Storage goes up only.

## Storage is separate

Storage does not come bundled with a compute class. It is its own axis, priced per gigabyte per month, and every app version carries a default:

- Small apps such as Vaultwarden, Pocket ID, and Memos default to 5 GB.
- Larger apps such as Forgejo, Kavita, and ActualBudget default to 10 GB.

Media libraries grow. If your Kavita collection is big, give the instance more storage at deploy time or resize up later. Storage can only grow.

## How billing works

Everything bills hourly against your organization's wallet:

- A **running** app bills its full allocation, computed from the same prices you see on the [pricing page](https://fluxvale.com/pricing).
- A **sleeping or stopped** app bills storage only. Sleeping is the scale-to-zero behavior described in [create your first app](/docs/getting-started/first-app).
- An **always-on** app bills its running rate around the clock.

The price you see at deploy time is honored for a year. After that the app bills at current prices.
