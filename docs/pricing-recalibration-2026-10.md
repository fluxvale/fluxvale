# Pricing recalibration 2026-10 — renewal infrastructure costs (#200)

**Status: PROPOSAL — awaiting the owner's pick.** Nothing here changes
shipped prices. The #186 machinery stays exactly as is
([ADR-0028](adr/00028-flat-rate-pricing.md) Am. 1): every option below
re-prices by changing the curve's constants and the seeded cents
**together**, so the table keeps reproducing through the formula and the
calibration tests keep passing by construction. The live table remains
[pricing-calibration.md](pricing-calibration.md) until a decision lands.

## TL;DR

NetCup renewal more than doubles the box cost (€21.61 → €46/mo,
current-tier equivalent). **At today's prices no tier breaks even at any
achievable fill** — the current tier needs 21 `small` instances to cover
its bill and tops out at 16. Three options:

- **A — ×2.2 full cost-cover**: `small` $6.15/mo; full bill covered at
  12 smalls (75% fill); 2.2× the market anchor.
- **B — ×1.65 self-sufficient box (recommended)**: `small` $4.61/mo; a
  full box (16 smalls) pays its full bill; 1.65× the anchor.
- **C — hold the anchor**: no change; bounded burn (~$13–45/mo), raise
  on a trigger.

Zero paying customers today (charges gated on the VAT registrations,
[ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3) — repricing now
is grandfathering-free.

## Cost basis at renewal rates

EUR/USD 1.12 ([pricing-calibration.md](pricing-calibration.md)'s stated
rate; ECB close 2026-10-21 = 1.1234 — ±0.3%, noise). Server rates are
the owner's renewal quotes from #200; NetCup's public G12.5 list
(€39.33 / €75.21 net monthly base, term discounts below) brackets them —
the owner's numbers rule.

| Item | EUR/mo | USD/mo | Class | Basis |
|---|---|---|---|---|
| Current-tier equivalent root server, Nuremberg (8 EPYC cores / 16 GB / 256 GB NVMe) | 46 | 51.52 | fixed | owner quote (#200); public list €39.33 net + VAT ≈ €46.80 |
| RS 4000 G12.5, Nuremberg (12 cores / 32 GB / 512 GB) | 87 | 97.44 | fixed | owner quote (#200); public list €75.21 base |
| Singapore location premium (either tier) | +15 | +16.80 | fixed per box | owner quote (#200) |
| `fluxvale.app` domain | — | ~1.70 | fixed | assumption: ~$20/yr |
| Postmark (sign-in codes, alerts) | — | 0 / 15.00 | semi-variable | assumption: free ≤100 emails/mo, $15/mo past it (token wired in `runtime.exs`; plan level not visible in this repo) |
| R2 (WAL-G backups, [ADR-0009](adr/00009-single-cnpg-cluster.md)) | — | <0.50 | fixed | assumption: platform DBs only, a few GB at $0.015/GB-mo; customer PVCs have no R2 path |
| Bitwarden SM (operator machine accounts, [ADR-0021](adr/00021-secrets-bws-operator.md)) | — | ~4.00 | fixed | assumption: Teams-plan floor |
| Grafana Cloud free, Cloudflare free | — | 0 | fixed | verified ([ADR-0012](adr/0012-observability-grafana-cloud.md), [architecture.md](architecture.md)) |
| HitPay fees | — | — | excluded | not live until the VAT gates clear (ADR-0029 Am. 3/4) |

Monthly fixed totals: **current tier $57.70 lean** (beta, ≤100 emails)
**/ $72.70 full** (Postmark paid); **RS 4000 $103.60 / $118.64**;
Singapore adds $16.80 to any box. Per-instance variable cost is
effectively $0 (traffic flat, storage local-NVMe, no per-instance backup
egress) — instances cover fixed costs by density, which is the whole
model.

## Density per tier

Pods request their full allocation (limits 2×; the ResourceQuota
mirrors), so density = min(cores ÷ cpu, RAM headroom ÷ ram). RAM
headroom: 8–10 GB on the current 16 GB box
([architecture.md](architecture.md)); ~24–26 GB on the RS 4000's 32 GB
(~4 GB platform + 2 GB safety).

| Size (cpu / RAM / disk) | Current tier (8c, 8–10 GB) | RS 4000 G12.5 (12c, 24–26 GB) |
|---|---|---|
| micro (0.25 / 512 MB / 5) | 16–20 (RAM) | 48 (CPU) |
| small (0.5 / 512 MB / 10) | **16 (CPU)** | **24 (CPU)** |
| medium (0.5 / 1 GB / 10) | 8–10 (RAM) | 24 |
| standard (1 / 2 GB / 20) | 4–5 (RAM) | 12 |
| plus (2 / 4 GB / 50) | 2 | 6 |
| pro (4 / 8 GB / 100) | 1 | 3 |

Notes: CPU (dedicated cores) binds `small`/`micro`; RAM binds `medium`+.
Caveats: platform pods carry their own CPU requests (~0.5–1 core) — the
16/24 caps may shave 1–2 smalls; the G12.5 renewal halves the
current-tier NVMe to 256 GB — 16 smalls = 160 GB + platform images is
tight but fits, and storage-heavy customs bind first. RS 4000 keeps
512 GB (48 micros = 240 GB, fine).

Per-unit economics at renewal: current tier $6.44/core, $5.72/GB-RAM;
RS 4000 $8.12/core, $3.90/GB-RAM. **CPU-bound fills (today's
`small`-only catalog) are cheaper per unit on the small box;
RAM-bound fills (`medium`+) are cheaper on the RS 4000.**

## The finding: current prices are underwater at renewal

Worst-case basis (the calibration doc's own frame): every instance at
`small` — the size both catalog apps recommend.

| Tier | Max-fill revenue (current prices) | Break-even | Verdict |
|---|---|---|---|
| current, Nuremberg | 16 × $2.79 = $44.64 | 21 smalls (lean) / 27 (full) | underwater at 100% fill |
| RS 4000, Nuremberg | 24 × $2.79 = $66.96 | 38 / 43 | worse — CPU-bound fill, pricier cores |
| RS 4000, micro fill | 48 × $2.36 = $113.28 | 44 (lean) | clears lean only — and `micro` is seeded but unsold |
| Singapore | — | +$16.80 on any row | strictly worse |

Why: the signed-off calibration priced `small` at $2.79 against a
€21.61 box (break-even 9 of 16 nominal). Renewal multiplies the box
2.13×; prices didn't move. Covering costs at renewal rates requires new
numbers — that's this proposal.

## Options

All options are a **uniform surcharge m** on every curve constant (the
v4 curve ×m — "curve v5" on implementation): exponents, rounding,
stopped-fee semantics, wizard UX, below-recommendation ack, and the
#121 snapshot/grace all unchanged. Prices below are the curve's exact
half-up cents at each allocation.

### Option A — full cost-cover (×2.2)

**Definition**: the full basis ($72.70, Postmark paid) is covered at
the conservative fill — 12 smalls, 75% of the current tier's cap.

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 5.18 | 44 |
| small | 6.15 | 74 |
| medium | 7.51 | 74 |
| standard | 11.39 | 125 |
| plus | 18.27 | 248 |
| pro | 29.45 | 417 |

Break-even (small basis): current tier 10 lean / 12 full; Singapore
13 / 15 (covered); RS 4000 17 / 20 of 24.

Margin, current tier, all-small fill (utilization of the 16 cap):

| Fill | Revenue | vs lean $57.70 | vs full $72.70 |
|---|---|---|---|
| 50% (8) | $49.20 | −17% | −48% |
| 70% (11) | $67.65 | +15% | −7% |
| 85% (13) | $79.95 | +28% | +9% |
| 100% (16) | $98.40 | +41% | +26% |

Market position: 2.2× the reference host — cost-safe, competitively
aggressive.

### Option B — self-sufficient box (×1.65) — **recommended**

**Definition**: the smallest round multiplier at which a full
current-tier box pays its full bill — full basis at the 16-small cap
(m = 72.72 ÷ (16 × $2.7949) = 1.627 → 1.65).

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 3.89 | 33 |
| small | 4.61 | 56 |
| medium | 5.63 | 56 |
| standard | 8.54 | 94 |
| plus | 13.70 | 186 |
| pro | 22.09 | 313 |

Break-even (small basis): current tier 13 lean / 16 full; Singapore
17 / 20 — **not covered on the current tier** (covered on the RS 4000's
lean basis only marginally, 23 of 24). RS 4000 small-fill never pays
for itself at B (CPU-bound: 24 × $4.61 = $110.64 < $118.64 full) —
stay on the small box while the catalog sells `small`.

Margin, current tier, all-small fill:

| Fill | Revenue | vs lean $57.70 | vs full $72.70 |
|---|---|---|---|
| 50% (8) | $36.88 | −57% | −97% |
| 70% (11) | $50.71 | −14% | −43% |
| 85% (13) | $59.93 | +4% | −21% |
| 100% (16) | $73.76 | +22% | +1% |

Market position: 1.65× the reference host — the "dedicated EPYC cores
vs shared vCPU" premium story.

### Option C — hold the anchor (×1.0, no change)

Prices stay as shipped. The box is a fixed beta cost paid regardless of
pricing; burn = basis − revenue:

| Running smalls | Revenue | Burn (lean / full) |
|---|---|---|
| 5 | $13.95 | −$43.77 / −$58.77 |
| 10 | $27.90 | −$29.82 / −$44.82 |
| 16 (cap) | $44.64 | −$13.08 / −$28.08 |

Raise on a trigger, not a date: production charges enabled (the VAT
gates), 12 smalls running, or the box #2 / renewal decision — whichever
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
months per instance — plus post-launch-rise optics.

## Interplay kept coherent (all options)

- **Stopped fee** scales with m (storage term × m): "pause it and it
  costs almost nothing" holds — `small` stopped $0.34 / $0.56 / $0.74
  (C / B / A).
- **Welcome credits ($3)**: runs a `small` for 32 / 20 / 15 days
  (C / B / A) and keeps it stopped for months. If A is picked, a $4–5
  grant is worth considering (owner call — acquisition math, not
  pricing machinery).
- **Below-recommendation ack + floors**: unchanged. A half-`small`
  custom (0.25 cpu / 256 MB / 5 GB) prices $2.00 / $3.30 / $4.40 —
  still below `small`, curve-continuous; the wizard's live estimate
  remains the charge by construction (#186).
- **Reproduction guarantee**: implementation changes the
  `PriceAllocation` constants and `pricing_data.yaml` cents in one PR
  (plus `pricing_data_test.exs` / `pricing_seed_test.exs` expectations
  and the calibration doc's table) — the YAML equals the curve at every
  size by construction.

## Recommendation

**B (×1.65), stay on the current tier at renewal, defer Singapore and
the RS 4000.**

1. Restores the honest reading of "per-instance prices cover costs at
   renewal rates": a full box pays its full bill, at the density the
   catalog actually sells.
2. 1.65× a shared-vCPU reference is a defensible dedicated-core
   premium; 2.2× for an unproven, two-app catalog risks the entry.
3. Reversible in either direction: A is a constant-bump away if margin
   at 70% fill becomes the bar; C's trigger frame is the fallback if
   traction disappoints.
4. The RS 4000 only pays off on RAM-bound mixes (`medium`+) — per-core
   economics favor the small box for today's `small`-only catalog.
   Revisit at the [ADR-0016](adr/00016-deferred-triggers.md) traction
   trigger, not before.
5. Singapore isn't covered at B — defer it ([ADR-0006](adr/00006-single-cluster-multi-region-ready.md)
   already defers regions) rather than distorting global prices for one
   location.

Rejected variants: a CPU-term-only reshape (more cost-faithful — cores
are the scarce input — but it abandons the anchor's relative shape and
prices our RAM-slack sizes hardest) and a per-location curve term (a
mechanism change, excluded by the issue's constraint).

**Decision requested on #200**: A / B / C or a named multiplier;
implementation then lands as one PR per the reproduction note above.
