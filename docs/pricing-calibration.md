# Pricing calibration — the ADR-0028 launch-gate check

Signed off by the maintainer 2026-10-12 (on
[#125](https://github.com/fluxvale/fluxvale/issues/125)). Re-check, don't
re-derive: `cd apps/platform && mix test
test/flux_vale/seeds/pricing_data_test.exs` re-asserts the table below
against the anchor on every run.

## The anchor: the market reference curve

Pricing is market-anchored ([ADR-0028](adr/00028-flat-rate-pricing.md)):
the reference point is what people in this category already pay at the
established managed-app hosts. Public docs don't name the source
([ADR-0018](adr/00018-repo-visibility.md) Am. 1 — competitor services
stay unnamed); the named extraction record is kept privately.

The anchor is the source's published per-resource pricing (version 4,
recorded 2026-10-12, **verified** against its public price calculator —
the calculator's displayed default of 0.25 core / 0.25 GB / 0 GB
computes to exactly the $1.80 it shows):

```text
$/mo = 1.35 · cores^0.6 + 0.734    (CPU, incl. per-instance base fee)
     + 1.45 · ram_gb^0.8           (memory)
     + 0.06 · storage_gb^0.75      (storage)
```

The same source (fetched 2026-10-12) prices stopped instances at
storage only, with a $1/mo per-instance minimum, ex-VAT. Our stopped
fee is the storage term alone — no $1 floor; "pause it and it costs
almost nothing" is the pitch
([ADR-0028](adr/00028-flat-rate-pricing.md) §2).

## The table

Prices are whole US cents (1 credit = 1 US cent), rounded half-up from
the anchor at each size's allocation. Live in
`priv/repo/seeds/pricing_data.yaml`; the shipped Forgejo version
recommends `small`.

| slug | CPU | RAM | Storage | $/mo running | stopped ¢/mo |
|---|---|---|---|---|---|
| micro | 0.25 | 512 MB | 5 GB | 2.36 | 20 |
| small | 0.5 | 512 MB | 10 GB | 2.79 | 34 |
| medium | 0.5 | 1 GB | 10 GB | 3.41 | 34 |
| standard | 1 | 2 GB | 20 GB | 5.18 | 57 |
| plus | 2 | 4 GB | 50 GB | 8.30 | 113 |
| pro | 4 | 8 GB | 100 GB | 13.39 | 190 |

## Density vs the box (the sanity check)

One box = the COGS anchor: Netcup RS 2000 G12, 8 dedicated EPYC cores /
16 GB ECC / 512 GB NVMe, **€21.61/mo** actual billed
([product.md](product.md)) ≈ **$24.20/mo** at EUR/USD 1.12 (1.1199 Yahoo
close 2026-10-11; 1.1259 FRED 2026-10-05 — 1.12 stated, drift noted
below). Platform overheads leave **~8–10 GB RAM** for customer instances
([architecture.md](architecture.md)'s resource budget) — RAM is the
binding constraint, as everywhere on this box.

Worst-case basis: every instance at `small` ($2.79) — the size the live
catalog actually sells (Forgejo's recommendation; `micro` is seeded for
future apps nothing references yet):

| Scenario | Fill (of 8–10 GB headroom) | Revenue/mo | vs COGS | Gross margin |
|---|---|---|---|---|
| conservative | 12 instances (6 GB) | $33.48 | 1.38× | 28% |
| nominal | 16 (8 GB) | $44.64 | 1.84× | 46% |
| aggressive | 20 (10 GB) | $55.80 | 2.31× | 57% |

**Break-even: 9 `small` instances.** Nominal fill is ~1.8× break-even;
storage is nowhere near binding (20 × 10 GB = 200 of ~460 usable GB).

Sensitivity: an all-`micro` fill (RAM allows the same densities — micro
is also 512 MB) clears COGS too: 12 × $2.36 = $28.32, 1.17× COGS;
break-even 11. No seeded size prices below micro, so this is the floor.

## What the check deliberately excludes

ADR-0028 scopes the gate to box COGS. Not modeled: R2 backups, Grafana
Cloud, Cloudflare, domain (free tiers at v1 scale); HitPay payment fees
(M6); FX drift on the €-denominated invoice; the second box's cost
arriving before its revenue (the growth model's overlap window). Revisit
the margin, not the anchor, when those get real.

## Changing prices

Edit `pricing_data.yaml` (or AshAdmin) and re-run seeds — convergence is
idempotent. The `pricing_data_test.exs` calibration tests fail on drift
from this anchor: re-anchor deliberately, update this doc in the same
PR, and note it on the issue. Instances snapshot their creation-time
price for one year from create, then reprice live (#121's call, shipped
with the settle trigger — existing rows were backfilled from their
version's size; sizeless legacy rows stay unpriced and logged).
