# Pricing recalibration 2026-10 — renewal infrastructure costs (#200)

**Status: PROPOSAL — awaiting the owner's pick.** Nothing here changes
shipped prices. The #186 machinery stays exactly as is
([ADR-0028](adr/00028-flat-rate-pricing.md) Am. 1): every option below
re-prices by changing the curve's constants and the seeded cents
**together**, so the table keeps reproducing through the formula and the
calibration tests keep passing by construction. The live table remains
[pricing-calibration.md](pricing-calibration.md) until a decision lands.

## Design principles (owner, 2026-10-22)

- **Pricing is per-datencenter.** Instances pay based on the actual
  server costs of the region they run in — a Nuremberg customer never
  subsidizes Singapore. Generalization rule: each region's **fleet cost
  is a pool** — a region's price floor scales with the SUM of its
  server costs, however many boxes that turns out to be.
- **Rolling rates are the floor** the business must clear; term
  discounts are margin, not a dependency.
- **Fleet plan: ONE Nuremberg box as long as demand allows.** The
  baseline options below are explicitly one-box: legacy €21.61 contract
  now, €87/mo rolling at renewal (€64/mo on 24-month terms — the
  actual-spend note). Singapore is a **contingent extension** with its
  own floor (€101/mo rolling), ready to adopt when its trigger fires —
  the Thalmyra playtest latency need — not an assumed day-one cost.

## TL;DR

At renewal the single Nuremberg box goes from €21.61 to €87/mo rolling
(~4.2× the basis the current prices were calibrated against).
**Today's prices are underwater at any sold fill on that floor**:
break-even is 38 `small` instances against a 24-per-box cap. Baseline
(one-box) options:

- **A — full cost-cover (×2.4)**: `small` $6.71/mo; the full rolling
  bill covered at 75% fill (18 of 24); 2.4× the market anchor.
- **B — self-sufficient box (×1.8, recommended)**: `small` $5.03/mo; a
  full box pays the full rolling bill at the cap (24/24); 1.8× the
  anchor.
- **C — hold the anchor (×1.0)**: no change; burn $37–90/mo lean on
  the renewal floor, raise on a trigger.

Singapore extension (contingent): same option definitions on the €101
rolling floor → A ×2.7 (`small` $7.55) / B ×2.05 ($5.73) — table in
[its section](#the-singapore-extension-contingent) below.

Zero paying customers today (charges gated on the VAT registrations,
[ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3) — repricing now
is grandfathering-free.

## Baseline cost basis (one Nuremberg box)

EUR/USD 1.12 ([pricing-calibration.md](pricing-calibration.md)'s stated
rate; ECB close 2026-10-21 = 1.1234 — ±0.3%, noise). Server rates are
the owner's authoritative figures (2026-10-22, #200), superseding the
issue's original €46 current-tier line and "+€15 additive".

| Item | EUR/mo rolling | USD/mo rolling | 24-mo term | Class | Basis |
|---|---|---|---|---|---|
| RS 4000 G12.5, Nuremberg (12 EPYC cores / 32 GB / 512 GB) — the pool from renewal | 87 | 97.44 | €64 → $71.68 | fixed | owner quote; public list €75.21 base |
| Current RS 2000 G12 contract — the pool until renewal | 21.61 | 24.20 | — | fixed | actual billed ([product.md](product.md)) |
| `fluxvale.app` domain | — | ~1.70 | — | fixed | assumption: ~$20/yr |
| Postmark (sign-in codes, alerts) | — | 0 / 15.00 | — | semi-variable | assumption: free ≤100 emails/mo, $15/mo past it (token wired in `runtime.exs`; plan level not visible in this repo) |
| R2 (WAL-G backups, [ADR-0009](adr/00009-single-cnpg-cluster.md)) | — | <0.50 | — | fixed | assumption: platform DBs only, a few GB at $0.015/GB-mo; customer PVCs have no R2 path |
| Bitwarden SM (operator machine accounts, [ADR-0021](adr/00021-secrets-bws-operator.md)) | — | ~4.00 | — | fixed | assumption: Teams-plan floor |
| Grafana Cloud free, Cloudflare free | — | 0 | — | fixed | verified ([ADR-0012](adr/00012-observability-grafana-cloud.md), [architecture.md](architecture.md)) |
| HitPay fees | — | — | — | excluded | not live until the VAT gates clear (ADR-0029 Am. 3/4) |

Nuremberg pool (server + $6.20 platform extras; +$15 Postmark on
"full"): **renewal floor $103.64 lean / $118.64 full**; **legacy,
until renewal: $30.40 / $45.40**. On 24-month terms the renewal box
actually spends $77.88 / $92.88 — a ~$26/mo cushion the pricing must
not depend on. Per-instance variable cost is effectively $0 (traffic
flat, storage local-NVMe, no per-instance backup egress) — instances
cover the pool by density, which is the whole model.

## Density per box (same hardware in every region)

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

## The finding: today's prices are underwater on the renewal floor

| Basis (`small` fill) | Max-fill revenue (current prices) | Break-even | Verdict |
|---|---|---|---|
| Nuremberg, renewal floor | 24 × $2.79 = $66.96 | 38 smalls (lean) / 43 (full) | underwater at 100% fill |
| Nuremberg, all-`micro` fill | 48 × $2.36 = $113.28 | 44 (lean) | clears lean only — `micro` is seeded but unsold |

Why: the signed-off calibration priced `small` at $2.79 against the
€21.61 box (break-even 9 of 16 nominal). Renewal puts the pool at ~4.2×
that basis; prices didn't move. Covering costs at renewal rates
requires new numbers. (The legacy contract makes today cash-comfortable
at almost any fill — that cushion expires with the contract, which is
the whole reason to reprice against the floor now.)

## Options (baseline: one Nuremberg box)

Every option is a **uniform surcharge m on the curve constants** (the
v4 curve ×m — "curve v5": exponents, rounding, stopped-fee semantics,
wizard UX, below-recommendation ack, and the #121 snapshot/grace all
unchanged). Prices are the curve's exact half-up cents at each
allocation; the Singapore extension applies the same definitions to
its own floor.

### Option A — full cost-cover (×2.4)

**Definition**: the **full** renewal-floor pool ($118.64) covered at
the conservative fill — 18 smalls, 75% of the cap
(m = 118.64 ÷ (18 × $2.7949) = 2.358; ×2.35 misses by $0.42 → ×2.4).

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 5.65 | 48 |
| small | 6.71 | 81 |
| medium | 8.19 | 81 |
| standard | 12.42 | 136 |
| plus | 19.93 | 271 |
| pro | 32.13 | 455 |

Break-even (`small` basis): 16 lean / 18 full of 24. Margin, all-
`small` fill (utilization of the 24 cap; basis $103.64 lean / $118.64
full):

| Fill | Revenue | vs lean | vs full |
|---|---|---|---|
| 50% (12) | $80.52 | −29% | −47% |
| 70% (16) | $107.36 | +3% | −11% |
| 85% (20) | $134.20 | +23% | +12% |
| 100% (24) | $161.04 | +36% | +26% |

Market position: 2.4× the reference host — cost-safe, competitively
aggressive.

### Option B — self-sufficient box (×1.8) — **recommended**

**Definition**: the smallest 0.05-granular multiplier at which a full
box pays the **full** rolling bill at the cap —
m = 118.64 ÷ (24 × $2.7949) = 1.769 → ×1.8 (×1.75 yields $117.39 <
$118.64).

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 4.24 | 36 |
| small | 5.03 | 61 |
| medium | 6.14 | 61 |
| standard | 9.32 | 102 |
| plus | 14.95 | 203 |
| pro | 24.09 | 342 |

Break-even (`small` basis): 21 lean / 24 full — full coverage lands
exactly at the cap.

Margin, all-`small` fill:

| Fill | Revenue | vs lean | vs full |
|---|---|---|---|
| 50% (12) | $60.36 | −72% | −97% |
| 70% (16) | $80.48 | −29% | −47% |
| 85% (20) | $100.60 | −3% | −18% |
| 100% (24) | $120.72 | +14% | +2% |

**Interim cushion**: until renewal the pool is the legacy $30.40 /
$45.40 — at B prices even 10 smalls run +40% lean / +10% full. The
prices never step up at renewal because they were set for the floor
all along; the legacy months are the cushion. On 24-month terms the
renewal box at cap runs ~+30% full. Market position: 1.8× the
reference host — the "dedicated EPYC cores vs shared vCPU" premium
story.

### Option C — hold the anchor (×1.0, no change)

Prices stay as shipped. The box is a fixed beta cost paid regardless
of pricing; burn = pool − revenue, stated positive (`small` fill):

| Pool | 5 smalls | 10 | 24 (cap) |
|---|---|---|---|
| Renewal floor, lean / full | $89.69 / $104.69 | $75.74 / $90.74 | $36.68 / $51.68 |
| Legacy (until renewal), lean / full | $16.45 / $31.45 | $2.50 / $17.50 | — (revenue covers) |

Raise on a trigger, not a date: production charges enabled (the VAT
gates), 18 smalls running, or the renewal/box decision — whichever
first. Grandfathering tail is bounded either way (below).

## The Singapore extension (contingent)

**Trigger** (owner): the Thalmyra playtest latency need for PH
players — the box arrives then, doubling as the FluxVale SG region.
Until it exists, no SG cost enters any baseline: the plan is one box
as long as demand allows.

**Floor**: RS 4000 G12.5 at €101/mo rolling (€75 on 24-month terms) —
the premium baked into the rate, not an additive. SG pool at one box:
$119.32 lean / $134.32 full. Same hardware ⇒ same 24-small density
cap. Thalmyra co-tenancy shares the box's real bill — the tables
below price FluxVale against the **full** SG pool (conservative); the
attribution split is an owner call outside this proposal.

Same option definitions applied to the SG floor (derivations: A:
134.32 ÷ 50.31 = 2.670 → ×2.7, ×2.65 misses by $0.94; B: 134.32 ÷
67.08 = 2.0024 → ×2.05, ×2.0 misses by $0.16):

| slug | A-SG $/mo | A-SG stopped ¢ | B-SG $/mo | B-SG stopped ¢ |
|---|---|---|---|---|
| micro | 6.36 | 54 | 4.83 | 41 |
| small | 7.55 | 91 | 5.73 | 69 |
| medium | 9.21 | 91 | 6.99 | 69 |
| standard | 13.98 | 153 | 10.61 | 116 |
| plus | 22.42 | 305 | 17.02 | 231 |
| pro | 36.14 | 512 | 27.44 | 389 |

Break-even (`small` basis): A-SG 16 lean / 18 full; B-SG 21 lean / 24
full — the same coverage structure as the baseline at a higher price
level (B-SG margins at 50/70/85/100%: −74/−30/−4/+13 lean,
−95/−47/−17/+2 full). At today's global prices SG would need 43–49
smalls — the extension exists precisely so an SG customer never
subsidizes or is subsidized: SG instances price on the SG floor from
the region's day one.

## The headroom sub-decision (region growth past one box)

The pooling rule is what happens when a region outgrows one box: its
price floor rises to the new fleet sum. Decide the treatment now, as
policy, so growth doesn't force a repricing debate later:

- **(a) Price for planned capacity**: set prices to the post-expansion
  fleet sum amortized over post-expansion density — a lower
  per-instance price, but underwater during every partial-fleet state
  (coverage only at ~full fleet fill).
- **(b) Margin absorbs the underutilization temporarily (recommended)**:
  keep per-box pricing — each box covered at its own cap — and let a
  new box's ramp eat margin until its fill catches up. Govern with
  triggers: order the next box in a region at ~85% fill of the current
  one, and evaluate the pool invariant (region revenue ≥ region
  server-sum) quarterly.

(b) fits the pool principle and never prices for capacity that may
arrive slower than planned; (a)'s lower prices can't be un-priced later
without the grandfathering optics this window exists to avoid.

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
months per instance — plus post-launch-rise optics. Setting the
baseline now also means the SG region, if its trigger fires, opens on
its own curve from day one.

## Interplay kept coherent (all options)

- **Stopped fee** scales with m (storage term × m): "pause it and it
  costs almost nothing" holds — `small` stopped $0.34 (C) / $0.61 (B)
  / $0.81 (A) baseline, $0.69 (B-SG) / $0.91 (A-SG) in the extension.
- **Welcome credits ($3)**: runs a `small` 32 days (C) / 18 (B) / 13
  (A) baseline, 16 (B-SG) / 12 (A-SG) in the extension — and keeps it
  stopped for months. If A is picked, a $5 grant is worth considering
  (owner call — acquisition math, not pricing machinery).
- **Below-recommendation ack + floors**: unchanged. A half-`small`
  custom (0.25 cpu / 256 MB / 5 GB) prices $2.00 (C) / $3.60 (B) /
  $4.80 (A) baseline, $4.10 (B-SG) / $5.40 (A-SG) — still below
  `small`, curve-continuous; the wizard's live estimate remains the
  charge by construction (#186).
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
with its 1-year grace (#121) — record region + price together. Until
an SG box exists, one region row ships. Schema and UX implications
belong to that lane, not this proposal.

## Recommendation

**B (×1.8) on the one-box baseline — the Singapore extension table
(×2.05) adopted only when its trigger fires — with treatment (b) on
growth and the 85%-fill box-add trigger.**

1. A full box pays the full no-commitment bill at the density the
   catalog actually sells, and the term-discount cushion stays margin,
   not a dependency.
2. The interim legacy pool makes B cash-positive from the first
   customers; prices never step up at renewal because they were set
   for the floor.
3. 1.8× a shared-vCPU reference is still a tellable dedicated-core
   premium ($5.03/mo for a managed Forgejo); A's 2.4× for an unproven
   two-app catalog risks the entry.
4. The SG extension keeps the pool principle honest without charging
   SG costs to Nuremberg customers or vice versa — and adopting it is
   a table lookup, not a new analysis.
5. Reversible: A is a constant-bump away if margin at 70% fill becomes
   the bar; C's trigger frame is the fallback if traction disappoints.

Rejected variants: a CPU-term-only reshape (more cost-faithful — cores
are the scarce input — but it abandons the anchor's relative shape and
prices our RAM-slack sizes hardest) and a global curve with an SG
surcharge line-item (breaks the "one price you see is the price"
flat-rate pitch; a per-region curve is cleaner than a visible fee).

**Decision requested on #200**: A / B / C (or a named multiplier) for
the baseline, plus the growth treatment (a)/(b) — the SG extension
table rides along as the contingent regional floor.
