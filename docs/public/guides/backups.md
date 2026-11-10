---
title: Backups
description: Back up your app's data to your own S3-compatible bucket on a daily schedule.
order: 40
slug: backups
---

FluxVale runs your apps. Your app's data is your responsibility. It survives only if it is backed up. The platform takes no platform-side copies.

The backup feature sends your app's data to a bucket you own, on a schedule, so a bad day stays a bad hour.

## Bring your own storage

Backups go to your own S3-compatible bucket. Cloudflare R2, or any MinIO or S3 endpoint, all work. You pay your provider for storage. FluxVale charges no fee for backups.

Setting backups up needs a one-time top-up of at least $5 in your wallet. That is a wallet minimum, not a charge. Every backup run needs a positive balance. Pausing backups and removing the settings are never gated, and restoring is never gated. Recovery must not depend on your wallet.

## Set it up

Open the app's instance page and find the **Backups** panel:

1. Enter your bucket's **Endpoint**, such as `https://account.r2.cloudflarestorage.com`.
2. Enter the **Bucket** name and, if you want, a folder prefix.
3. Enter the bucket's **Access key id** and **Secret access key**. The secret is stored in the app's own namespace and never shown again.
4. Choose how many **Snapshots to keep**, between 2 and 30. The default is 7.
5. Press **Set up backups**.

Snapshots run daily. The credentials live in your app's namespace, and the data is encrypted client-side before it leaves the cluster.

## The backup password

When backups are configured, the panel shows a backup password. Copy it and keep it somewhere safe. You need it to restore these backups into a new app if this one is deleted. It is not shown anywhere else.

## Run, pause, restore

- **Back up now** runs a snapshot outside the schedule.
- **Pause backups** stops the schedule. **Resume** restarts it.
- **Stop backing up** removes the settings. Snapshots already in your bucket stay there.
- **Restore latest** puts the newest successful snapshot back into the same app. The app is turned off until the restore finishes, and the restore replaces the app's current data.

Restoring into a different app is not offered in the panel today. With the backup password and the snapshots in your bucket, the data remains yours to restore with standard tools.

## What a snapshot is

A snapshot is a crash-consistent copy of the app's volume, taken with restic while the app runs. Databases inside the volume are not quiesced. For most self-hosted apps this is fine. For a database you depend on, schedule around it or check what the app's own docs say about snapshot restores.
