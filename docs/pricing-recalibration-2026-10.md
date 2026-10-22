# Pricing recalibration 2026-10 — renewal infrastructure costs (#200)

**Status: PROPOSAL — awaiting the owner's pick.** Nothing here changes
shipped prices. The #186 machinery stays exactly as is
([ADR-0028](adr/00028-flat-rate-pricing.md) Am. 1): every option below
re-prices by changing the curve's constants and the seeded cents
**together**, so the table keeps reproducing through the formula and the
calibration tests keep passing by construction. The live table remains
[pricing-calibration.md](pricing-calibration.md) until a decision lands.

## Design principle: pricing is per-datencenter (owner, 2026-10-22)

Instances pay based on the actual server costs of **the region they run
in** — a Nuremberg customer never subsidizes Singapore. Each region's
server **fleet cost is a pool**: region revenue must cover the SUM of
that region's server costs (two SG boxes ⇒ SG instances carry both), not
a per-server allocation. EU-US pool: the legacy €21.61 contract until
renewal, then the €87 rolling floor. SG pool: €101 rolling per
RS-4000-class box. Policy: **rolling rates are the floor** the business
must clear; term discounts are margin, not a dependency.

## TL;DR

**At today's (global) prices both regions are underwater at any sold
fill**: break-even is 38 `small` instances in EU-US and 43 in Singapore
against a 24-per-box cap. Per-region options:

- **A — full cost-cover**: EU-US ×2.4 (`small` $6.71/mo), SG ×2.7
  ($7.55); each region's full rolling bill covered at 75% fill.
- **B — self-sufficient box (recommended)**: EU-US ×1.8 (`small`
  $5.03/mo), SG ×2.05 ($5.73); a full box pays its region's full
  rolling bill at the cap (24/24, both regions).
- **C — hold the anchor**: no change; burn $37–90/mo lean per region,
  raise on a trigger.

Zero paying customers today (charges gated on the VAT registrations,
[ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3) — repricing now
is grandfathering-free.

## Cost basis at renewal rates (per-region pools, rolling = the floor)

EUR/USD 1.12 ([pricing-calibration.md](pricing-calibration.md)'s stated
rate; ECB close 2026-10-21 = 1.1234 — ±0.3%, noise). Server rates are
the owner's authoritative figures (2026-10-22, #200), superseding the
issue's original €46 current-tier line and "+€15 additive" — the
topology is RS-4000-class in both locations, Singapore's premium baked
into its own rate.

| Pool | EUR/mo rolling | USD/mo rolling | 24-mo term | Basis |
|---|---|---|---|---|
| EU-US: RS 4000 G12.5 (Nuremberg/Vienna/Manassas class, 12 EPYC cores / 32 GB / 512 GB) | 87 | 97.44 | €64 → $71.68 | owner quote; public list €75.21 base |
| EU-US legacy: current RS 2000 G12 contract — **the pool until renewal** | 21.61 | 24.20 | — | actual billed ([product.md](product.md)) |
| SG: RS 4000 G12.5, per box (pool = sum over boxes) | 101 | 113.12 | €75 → $84.00 | owner quote; premium baked in |

Region pools (server + $6.20 platform extras + $15 Postmark on "full";
extras attach to each region in full — conservative, and a ~$6/mo
over-allocation when both regions are live, worth <1 instance of
break-even):

| Region pool | Lean | Full |
|---|---|---|
| EU-US (post-renewal) | $103.64 | $118.64 |
| EU-US (legacy, until renewal) | $30.40 | $45.40 |
| SG, one box | $119.32 | $134.32 |
| SG, two boxes | $232.44 | $247.44 |

Per-instance variable cost is effectively $0 (traffic flat, storage
local-NVMe, no per-instance backup egress) — instances cover the pool
by density, which is the whole model.

**Fleet shape** (context): the Singapore box arrives with the Thalmyra
alpha (PH-player latency) and doubles as the FluxVale SG region;
Nuremberg remains and renews at RS-4000-class. Under per-region pools,
Thalmyra co-tenancy shares the SG box's real bill — this doc prices
FluxVale against the **full** SG pool (conservative); the attribution
split is an owner call outside this proposal.

## Density per box (identical in both regions — same hardware)

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

Worst-case revenue basis throughout (the calibration doc's own frame):
every instance at `small` — the size both catalog apps recommend.

## The finding: today's global prices are underwater in both regions

| Region (rolling, `small` fill) | Max-fill revenue | Break-even | Verdict |
|---|---|---|---|
| EU-US | 24 × $2.79 = $66.96 | 38 smalls (lean) / 43 (full) | underwater at 100% fill |
| SG | 24 × $2.79 = $66.96 | 43 / 49 | worse — the premium bites with no density gain |
| EU-US, all-`micro` fill | 48 × $2.36 = $113.28 | 44 (lean) | clears EU lean only — `micro` is seeded but unsold; clears nothing in SG |

Why: the signed-off calibration priced `small` at $2.79 against a
€21.61 box (break-even 9 of 16 nominal). Renewal puts the cheaper
region's pool at ~4.2× that basis; prices didn't move. Covering costs
at renewal rates requires new numbers — per region.

## Options

Every option is a **uniform surcharge m on the curve constants, per
region** (the v4 curve ×m — "curve v5": exponents, rounding,
stopped-fee semantics, wizard UX, below-recommendation ack, and the
#121 snapshot/grace all unchanged; the region dimension itself is
implementation scope — below). Prices are the curve's exact half-up
cents at each allocation.

### Option A — full cost-cover per region (EU ×2.4 / SG ×2.7)

**Definition**: each region's **full** pool covered at the conservative
fill — 18 smalls, 75% of the cap. EU: 118.64 ÷ (18 × $2.7949) = 2.358
→ ×2.4 (2.35 misses by $0.42). SG: 134.32 ÷ 50.31 = 2.670 → ×2.7
(2.65 misses by $0.94).

| slug | EU-US $/mo | SG $/mo | EU stopped ¢ | SG stopped ¢ |
|---|---|---|---|---|
| micro | 5.65 | 6.36 | 48 | 54 |
| small | 6.71 | 7.55 | 81 | 91 |
| medium | 8.19 | 9.21 | 81 | 91 |
| standard | 12.42 | 13.98 | 136 | 153 |
| plus | 19.93 | 22.42 | 271 | 305 |
| pro | 32.13 | 36.14 | 455 | 512 |

Break-even (`small` basis): EU 16 lean / 18 full; SG 16 lean / 18 full
— identical structure, different price levels.

Margin per region, all-`small` fill (utilization of the 24 cap; EU
basis $103.64/$118.64, SG $119.32/$134.32):

| Fill | EU rev | EU lean | EU full | SG rev | SG lean | SG full |
|---|---|---|---|---|---|---|
| 50% (12) | $80.52 | −29% | −47% | $90.60 | −32% | −48% |
| 70% (16) | $107.36 | +3% | −11% | $120.80 | +1% | −11% |
| 85% (20) | $134.20 | +23% | +12% | $151.00 | +21% | +11% |
| 100% (24) | $161.04 | +36% | +26% | $181.20 | +34% | +26% |

Market position: 2.4×/2.7× the reference host — cost-safe in both
regions, competitively aggressive.

### Option B — self-sufficient box per region (EU ×1.8 / SG ×2.05) — **recommended**

**Definition**: the smallest 0.05-granular multiplier per region at
which a full box pays that region's **full** rolling bill at the cap.
EU: 118.64 ÷ (24 × $2.7949) = 1.769 → ×1.8 (×1.75 yields $117.39).
SG: 134.32 ÷ 67.08 = 2.0024 → ×2.05 (×2.0 yields $134.16, short
$0.16).

| slug | EU-US $/mo | SG $/mo | EU stopped ¢ | SG stopped ¢ |
|---|---|---|---|---|
| micro | 4.24 | 4.83 | 36 | 41 |
| small | 5.03 | 5.73 | 61 | 69 |
| medium | 6.14 | 6.99 | 61 | 69 |
| standard | 9.32 | 10.61 | 102 | 116 |
| plus | 14.95 | 17.02 | 203 | 231 |
| pro | 24.09 | 27.44 | 342 | 389 |

Break-even (`small` basis): EU 21 lean / 24 full; SG 21 lean / 24
full — full coverage lands exactly at each region's cap.

Margin per region, all-`small` fill:

| Fill | EU rev | EU lean | EU full | SG rev | SG lean | SG full |
|---|---|---|---|---|---|---|
| 50% (12) | $60.36 | −72% | −97% | $68.76 | −74% | −95% |
| 70% (16) | $80.48 | −29% | −47% | $91.68 | −30% | −47% |
| 85% (20) | $100.60 | −3% | −18% | $114.60 | −4% | −17% |
| 100% (24) | $120.72 | +14% | +2% | $137.52 | +13% | +2% |

**Interim cushion**: until renewal, the EU pool is the legacy $30.40 /
$45.40 — at B-EU prices even 10 smalls run +40% lean / +10% full, so
the pre-renewal months are comfortably cash-positive. On 24-month
terms (actual-spend note), each region at cap runs ~+30% full — the
term-discount cushion the policy keeps as margin. Market position:
1.8×/2.05× the reference host — the "dedicated EPYC cores vs shared
vCPU" premium story, SG's slice visibly paying for SG.

### Option C — hold the anchor (×1.0, no change)

Prices stay as shipped. The boxes are a fixed beta cost paid regardless
of pricing; burn = pool − revenue, stated positive (rolling, `small`
fill):

| Region | 5 smalls | 10 | 24 (cap) |
|---|---|---|---|
| EU-US (post-renewal) lean / full | $89.69 / $104.69 | $75.74 / $90.74 | $36.68 / $51.68 |
| SG (one box) lean / full | $105.37 / $120.37 | $91.42 / $106.42 | $52.36 / $67.36 |

Raise on a trigger, not a date: production charges enabled (the VAT
gates), 18 smalls running in a region, or the SG box order — whichever
first. Grandfathering tail is bounded either way (below).

## The headroom sub-decision (second box before density fills the first)

Per-region pools make expansion a pricing question: when a second SG
box arrives before the first fills, either the prices or the margin
carries the underutilization. Both treatments, at B-SG ($5.73):

- **(a) Price for planned capacity**: key prices to the 2-box pool at
  2-box density — SG ×1.85, `small` $5.17, break-even 48 of 48. Lower
  per-instance price, but underwater during every partial-fleet state
  (even a full first box runs $124.08 vs the $134.32 it must carry,
  −8%): coverage only exists at ~100% fleet fill.
- **(b) Margin absorbs the underutilization temporarily** (fits the
  pool principle): keep per-box pricing ($5.73, each box covered at
  its own cap) and let the second box's empty capacity eat margin
  until fill catches up: 24 smalls on 2 boxes = −80% full; 36 = −20%;
  42 = −3%; 48 = +10%.

**Recommendation on the sub-decision: (b)**, with the box-add trigger
doing the governing: order the next box in a region at ~85% fill of
the current one (20–21 smalls), and evaluate the pool invariant
(region revenue ≥ region server-sum) quarterly. Treatment (a) prices
for a future that may arrive slower than planned and can't be
un-priced later without the same grandfathering optics this window
exists to avoid.

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
also means the SG region opens on its own curve from day one.

## Interplay kept coherent (all options)

- **Stopped fee** scales with m (storage term × m): "pause it and it
  costs almost nothing" holds — `small` stopped $0.34 (C) / $0.61 EU,
  $0.69 SG (B) / $0.81 EU, $0.91 SG (A).
- **Welcome credits ($3)**: runs a `small` 32 days (C) / 18 EU, 16 SG
  (B) / 13 EU, 12 SG (A) and keeps it stopped for months. If A is
  picked, a $5 grant is worth considering (owner call — acquisition
  math, not pricing machinery).
- **Below-recommendation ack + floors**: unchanged. A half-`small`
  custom (0.25 cpu / 256 MB / 5 GB) prices $2.00 (C) / $3.60 EU, $4.10
  SG (B) / $4.80 EU, $5.40 SG (A) — still below `small`,
  curve-continuous; the wizard's live estimate remains the charge by
  construction (#186).
- **Reproduction guarantee**: implementation changes the
  `PriceAllocation` constants and `pricing_data.yaml` cents in one PR
  (plus `pricing_data_test.exs` / `pricing_seed_test.exs` expectations
  and the calibration doc's table) — the YAML equals the curve at every
  size by construction.

## Implementation lane (out of scope here — flagged for the follow-up)

Per-region pricing adds a **region dimension to prices**; today the
anchor curve is global. The extension is natural: the Cluster registry
already carries the region dimension (its `name` is the region-routing
key — v1's ResolveClusterFromRegion,
[ADR-0006](adr/00006-single-cluster-multi-region-ready.md)), so the
curve gains a region parameter and the deploy-time surfaces — the
wizard's live estimate (#184) and the creation-time price snapshot
with its 1-year grace (#121) — record region + price together. Schema
and UX implications belong to that lane, not this proposal.

## Recommendation

**B per region — EU-US ×1.8 (`small` $5.03), SG ×2.05 ($5.73) — with
treatment (b) on expansion and the 85%-fill box-add trigger.**

1. The pool principle made concrete: each region's full rolling bill
   is paid by a full box of that region's customers, at the density
   the catalog sells — no cross-subsidy in either direction, and the
   term-discount cushion stays margin, not a dependency.
2. 1.8×/2.05× a shared-vCPU reference is still a tellable
   dedicated-core premium ($5.03–5.73/mo for a managed Forgejo); A's
   2.4×/2.7× for an unproven two-app catalog risks the entry.
3. The interim legacy pool makes B cash-positive from the first
   customers, not just at renewal.
4. Reversible: A is a constant-bump away if margin at 70% fill becomes
   the bar; C's trigger frame is the fallback if traction disappoints.
5. `micro` (the only size that doubles box capacity) is seeded but
   unsold; if a future catalog app recommends it, both regions'
   margins improve on their own.

Rejected variants: a CPU-term-only reshape (more cost-faithful — cores
are the scarce input — but it abandons the anchor's relative shape and
prices our RAM-slack sizes hardest) and a global curve with an SG
surcharge line-item (breaks the "one price you see is the price"
flat-rate pitch; a per-region curve is cleaner than a visible fee).

**Decision requested on #200**: A / B / C (or named per-region
multipliers) plus the expansion treatment (a)/(b); implementation then
lands as one PR per the reproduction note above.
