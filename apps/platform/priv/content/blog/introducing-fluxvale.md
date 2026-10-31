---
title: Introducing FluxVale
description: FluxVale is a platform for self-hosted apps. Your apps sleep until you need them, and stay reachable only by you if that's what you want.
date: 2026-10-31
slug: introducing-fluxvale
author: Terence Ponce
---

This is the first post on the FluxVale blog. Short version of what we are: a platform where you deploy the self-hosted apps you already use, and we run them for you.

The apps sleep until someone uses them. A visit wakes one up in under a minute, and it goes back to sleep when the traffic stops. You are not paying to keep an idle app running.

You can also make an app private. A private app has no public address at all. It is reachable only from your own devices, through your own network, under your own domain. Public apps get a normal `something.fluxvale.app` address and work the way you expect.

Who this is for: people who run apps like Kavita, or Uptime Kuma, or a wiki, and are tired of choosing between a VPS they have to babysit and a big cloud bill for hardware that sits idle. If you have ever moved a YAML file at 2am to fix an app only you use, you are the person we built this for.

Where we are today: early. It works, we run on it ourselves, and the pricing is simple. Apps are billed by size, an access gateway for private apps is $2 a month, and the default `fluxvale.app` address is free.

What's next gets written here. We will post about new features as they land, and about the parts of running a small platform that are worth sharing.

Thanks for reading. If you want to see it, the catalog is public.
