# Pricing recalibration 2026-10 — renewal infrastructure costs (#200)

**Status: PROPOSAL — awaiting the owner's pick.** Nothing here changes
shipped prices. The #186 machinery stays exactly as is
([ADR-0028](adr/00028-flat-rate-pricing.md) Am. 1): every option below
re-prices by changing the curve's constants and the seeded cents
**together**, so the table keeps reproducing through the formula and the
calibration tests keep passing by construction. The live table remains
[pricing-calibration.md](pricing-calibration.md) until a decision lands.

## TL;DR

At renewal, both locations run RS 4000 G12.5-class boxes at **rolling
rates** — the owner-set policy: the no-commitment cost is the floor the
business must clear; term discounts are margin, not a dependency.
**At today's prices both locations are underwater at any `small` fill**
(`small` is what the catalog sells): break-even is 38–49 smalls against
a 24-per-box cap. Three options:

- **A — ×2.4 full cost-cover**: `small` $6.71/mo; the full bill covered
  at 75% fill (18 of 24); 2.4× the market anchor.
- **B — ×1.8 self-sufficient box (recommended)**: `small` $5.03/mo; a
  full Nuremberg box pays its full rolling bill at the cap (24/24);
  1.8× the anchor.
- **C — hold the anchor**: no change; bounded burn ($37–90/mo lean,
  Nuremberg rolling), raise on a trigger.

Zero paying customers today (charges gated on the VAT registrations,
[ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3) — repricing now
is grandfathering-free.

## Cost basis at renewal rates (rolling = the floor)

EUR/USD 1.12 ([pricing-calibration.md](pricing-calibration.md)'s stated
rate; ECB close 2026-10-21 = 1.1234 — ±0.3%, noise). Server rates are
the owner's authoritative figures (2026-10-22 correction on #200),
which **supersede the issue's inputs** — the €46 current-tier
equivalent and the "+€15 Singapore additive" are both replaced: the
topology is RS-4000-class in both locations, Singapore's premium baked
into its own rate. Pricing models the rolling (no-commitment) rate; the
24-month figure is shown as the actual-spend note.

| Item | EUR/mo rolling | USD/mo rolling | 24-mo term | Class | Basis |
|---|---|---|---|---|---|
| RS 4000 G12.5, Nuremberg (12 EPYC cores / 32 GB / 512 GB) | 87 | 97.44 | €64 → $71.68 | fixed | owner quote (#200 correction); public list €75.21 base |
| RS 4000 G12.5, Singapore (same hardware) | 101 | 113.12 | €75 → $84.00 | fixed | owner quote (#200 correction) — premium baked in, not additive |
| Current box (RS 2000 G12, 8c/16GB) — **legacy line until renewal** | 21.61 | 24.20 | — | fixed | actual billed ([product.md](product.md)) |
| `fluxvale.app` domain | — | ~1.70 | — | fixed | assumption: ~$20/yr |
| Postmark (sign-in codes, alerts) | — | 0 / 15.00 | — | semi-variable | assumption: free ≤100 emails/mo, $15/mo past it (token wired in `runtime.exs`; plan level not visible in this repo) |
| R2 (WAL-G backups, [ADR-0009](adr/00009-single-cnpg-cluster.md)) | — | <0.50 | — | fixed | assumption: platform DBs only, a few GB at $0.015/GB-mo; customer PVCs have no R2 path |
| Bitwarden SM (operator machine accounts, [ADR-0021](adr/00021-secrets-bws-operator.md)) | — | ~4.00 | — | fixed | assumption: Teams-plan floor |
| Grafana Cloud free, Cloudflare free | — | 0 | — | fixed | verified ([ADR-0012](adr/00012-observability-grafana-cloud.md), [architecture.md](architecture.md)) |
| HitPay fees | — | — | — | excluded | not live until the VAT gates clear (ADR-0029 Am. 3/4) |

Monthly fixed bases (server + $6.20 platform extras; +$15 Postmark on
"full"): **Nuremberg $103.64 lean / $118.64 full**; **Singapore
$119.32 / $134.32**; **both-box fleet $216.76 / $231.76**. At 24-month
terms the fleet actually spends $161.88 / $176.88 — a $55/mo cushion
the pricing must not depend on. Per-instance variable cost is
effectively $0 (traffic flat, storage local-NVMe, no per-instance
backup egress) — instances cover fixed costs by density, which is the
whole model.

**Fleet shape and attribution** (context, not a decision): the Singapore
box arrives with the Thalmyra alpha (PH-player latency) and doubles as
the FluxVale SG region; Nuremberg remains and renews at RS-4000-class.
This doc prices FluxVale against each box's **full** cost — the
conservative basis; how Thalmyra co-tenancy splits the Singapore bill
is an owner call outside this proposal.

## Density per box (identical in both locations — same hardware)

Pods request their full allocation (limits 2×; the ResourceQuota
mirrors), so density = min(cores ÷ cpu, RAM headroom ÷ ram). RAM
headroom on the 32 GB box: ~24–26 GB (~4 GB platform + 2 GB safety).

| Size (cpu / RAM / disk) | RS 4000 G12.5 (12c, 24–26 GB) |
|---|---|
| micro (0.25 / 512 MB / 5) | 48 (CPU) |
| small (0.5 / 512 MB / 10) | **24 (CPU)** |
| medium (0.5 / 1 GB / 10) | 24 |
| standard (1 / 2 GB / 20) | 12 |
| plus (2 / 4 GB / 50) | 6 |
| pro (4 / 8 GB / 100) | 3 |

- CPU (dedicated cores) binds every size from `small` up; `micro`
  (0.25c / 0.5 GB) is the one size that balances the box's 1:2
  core:GB ratio.
- Platform pods carry their own CPU requests (~0.5–1 core) — the 24
  cap may shave 1–2 smalls.
- Storage (512 GB, ~460 usable): 24 smalls = 240 GB, 48 micros =
  240 GB — fine; storage-heavy custom allocations bind first.
- Legacy box context (until renewal): 8c/16 GB fits 16 smalls — it
  disappears from the decision basis at renewal.

Worst-case revenue basis throughout (the calibration doc's own frame):
every instance at `small` — the size both catalog apps recommend.

## The finding: current prices are underwater at renewal

| Basis (rolling) | Max-fill revenue (current prices) | Break-even | Verdict |
|---|---|---|---|
| Nuremberg | 24 × $2.79 = $66.96 | 38 smalls (lean) / 43 (full) | underwater at 100% fill |
| Singapore | 24 × $2.79 = $66.96 | 43 / 49 | worse — the premium bites with no density gain |
| both-box fleet | 48 × $2.79 = $133.92 | 78 / 84 | underwater at 100% fleet fill |
| Nuremberg, all-`micro` fill | 48 × $2.36 = $113.28 | 44 (lean) | clears Nuremberg lean only — `micro` is seeded but unsold; clears nothing in Singapore |

Why: the signed-off calibration priced `small` at $2.79 against a
€21.61 box (break-even 9 of 16 nominal). Renewal puts even the cheaper
location at 4.2× that box cost; prices didn't move. Covering costs at
renewal rates requires new numbers — that's this proposal.

## Options

All options are a **uniform surcharge m** on every curve constant (the
v4 curve ×m — "curve v5" on implementation): exponents, rounding,
stopped-fee semantics, wizard UX, below-recommendation ack, and the
#121 snapshot/grace all unchanged. Prices below are the curve's exact
half-up cents at each allocation.

### Option A — full cost-cover (×2.4)

**Definition**: the Nuremberg **full** basis ($118.64) covered at the
conservative fill — 18 smalls, 75% of the cap
(m = 118.64 ÷ (18 × $2.7949) = 2.358; 2.35 misses by $0.42 → ×2.4).

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 5.65 | 48 |
| small | 6.71 | 81 |
| medium | 8.19 | 81 |
| standard | 12.42 | 136 |
| plus | 19.93 | 271 |
| pro | 32.13 | 455 |

Break-even (`small` basis): Nuremberg 16 lean / 18 full; Singapore
18 / 21 (covered); fleet 33 / 35 of 48.

Margin, Nuremberg, all-`small` fill (utilization of the 24 cap):

| Fill | Revenue | vs lean $103.64 | vs full $118.64 |
|---|---|---|---|
| 50% (12) | $80.52 | −29% | −47% |
| 70% (16) | $107.36 | +3% | −11% |
| 85% (20) | $134.20 | +23% | +12% |
| 100% (24) | $161.04 | +36% | +26% |

Fleet at cap (48): +33% lean / +28% full. Market position: 2.4× the
reference host — cost-safe everywhere including Singapore full,
competitively aggressive.

### Option B — self-sufficient box (×1.8) — **recommended**

**Definition**: the smallest 0.05-granular multiplier at which a full
Nuremberg box pays its **full** rolling bill at the cap —
m = 118.64 ÷ (24 × $2.7949) = 1.769 (×1.75 yields $117.39 < $118.64;
×1.8 clears).

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 4.24 | 36 |
| small | 5.03 | 61 |
| medium | 6.14 | 61 |
| standard | 9.32 | 102 |
| plus | 14.95 | 203 |
| pro | 24.09 | 342 |

Break-even (`small` basis): Nuremberg 21 lean / 24 full — full
coverage lands exactly at the cap. Singapore 24 lean (exactly at cap) /
27 full — **Singapore's full bill is not covered at B**; lean is, and
the Thalmyra co-tenancy shares that box's real bill. Fleet 44 lean /
47 full of 48.

Margin, Nuremberg, all-`small` fill:

| Fill | Revenue | vs lean $103.64 | vs full $118.64 |
|---|---|---|---|
| 50% (12) | $60.36 | −72% | −97% |
| 70% (16) | $80.48 | −29% | −47% |
| 85% (20) | $100.60 | −3% | −18% |
| 100% (24) | $120.72 | +14% | +2% |

Fleet at cap (48): +10% lean / +4% full; on 24-month actual spend the
Nuremberg box at cap runs +55% lean / +30% full — the term-discount
cushion the policy keeps as margin. Market position: 1.8× the
reference host — the "dedicated EPYC cores vs shared vCPU" premium
story.

### Option C — hold the anchor (×1.0, no change)

Prices stay as shipped. The boxes are a fixed beta cost paid regardless
of pricing; burn = basis − revenue, stated positive (Nuremberg rolling,
`small` fill):

| Running smalls | Revenue | Burn (lean / full) |
|---|---|---|
| 5 | $13.95 | $89.69 / $104.69 |
| 10 | $27.90 | $75.74 / $90.74 |
| 24 (cap) | $66.96 | $36.68 / $51.68 |

Raise on a trigger, not a date: production charges enabled (the VAT
gates), 18 smalls running, or the Singapore box order — whichever
first. Grandfathering tail is bounded either way (below).

## Timing — the zero-customers window

Production charges are gated on the [ADR-0029](adr/00029-payments-adapter-selfmor.md)
Am. 3 registrations, so there are zero paying customers today. **A
change now touches nobody** — no grandfathering, no communication, no
delta optics. (Any beta instances ride welcome credits and hold their
creation-time snapshot anyway; instance count isn't verifiable from
this repo — assumption.)

If pricing waits until after first customers: new instances price live
immediately; each existing instance keeps its creation-time cents for
up to 12 months (#121's 1-year grace), so the cost of waiting ≈
(new − old) × sold instances × average remaining grace, bounded at 12
months per instance — plus post-launch-rise optics. Setting prices now
also means the Singapore region opens on the same curve, with no
location repricing event later.

## Interplay kept coherent (all options)

- **Stopped fee** scales with m (storage term × m): "pause it and it
  costs almost nothing" holds — `small` stopped $0.34 / $0.61 / $0.81
  (C / B / A).
- **Welcome credits ($3)**: runs a `small` for 32 / 18 / 13 days
  (C / B / A) and keeps it stopped for months. If A is picked, a $5
  grant is worth considering (owner call — acquisition math, not
  pricing machinery).
- **Below-recommendation ack + floors**: unchanged. A half-`small`
  custom (0.25 cpu / 256 MB / 5 GB) prices $2.00 / $3.60 / $4.80 —
  still below `small`, curve-continuous; the wizard's live estimate
  remains the charge by construction (#186).
- **Reproduction guarantee**: implementation changes the
  `PriceAllocation` constants and `pricing_data.yaml` cents in one PR
  (plus `pricing_data_test.exs` / `pricing_seed_test.exs` expectations
  and the calibration doc's table) — the YAML equals the curve at every
  size by construction.

## Recommendation

**B (×1.8), renew Nuremberg at RS-4000-class rolling rates, let
Singapore arrive with the Thalmyra alpha on the same curve.**

1. Restores the honest reading of "per-instance prices cover costs at
   renewal rates" under the owner's policy: a full Nuremberg box pays
   its full no-commitment bill, at the density the catalog actually
   sells — and the term-discount cushion stays margin, not a
   dependency.
2. 1.8× a shared-vCPU reference is still a tellable dedicated-core
   premium ($5.03/mo for a managed Forgejo); 2.4× for an unproven
   two-app catalog risks the entry.
3. Singapore rides: lean covered exactly at cap, and the box's real
   bill is shared with Thalmyra anyway. If FluxVale-SG must carry its
   box alone at full basis, that's A's numbers — a constant-bump away.
4. Reversible: A is a multiplier change if margin at 70% fill becomes
   the bar; C's trigger frame is the fallback if traction disappoints.
5. `micro` (the only size that doubles box capacity) is seeded but
   unsold; if a future catalog app recommends it, B's fleet margins
   improve on their own.

Rejected variants: a CPU-term-only reshape (more cost-faithful — cores
are the scarce input — but it abandons the anchor's relative shape and
prices our RAM-slack sizes hardest) and a per-location curve term (a
mechanism change, excluded by the issue's constraint).

**Decision requested on #200**: A / B / C or a named multiplier;
implementation then lands as one PR per the reproduction note above.
