# Pricing recalibration 2026-10 — renewal infrastructure costs (#200)

**Status: DECIDED — B′ ×1.2 (2026-10-22).** The owner picked B′ from
the options below (#200; implemented on #206); B′-SG ×1.25 stays on
standby. The model sections stand as the derivation record; the live
table is [pricing-calibration.md](pricing-calibration.md). The #186
machinery stayed exactly as is
([ADR-0028](adr/00028-flat-rate-pricing.md) Am. 1): the re-price
surcharged the curve (a per-region ×1.2 multiplier on the unchanged
v4 constants) and re-seeded the cents **together**, so the table
keeps reproducing through the formula and the calibration tests keep
passing by construction.

## Design principles (owner, 2026-10-22)

- **FluxVale does not sell dedicated resources.** The bet is
  RepoCloud-style oversubscription: most instances idle most of the
  time; instances unused for a while **scale to zero automatically**
  (pods at 0 — RAM and CPU freed), **waking on use** via an
  edge-intercepted cold start. Auto-idle is platform-internal and
  distinct from **user-paused** (stopped = storage-only fee); an
  idling instance keeps paying its running rate
  ([ADR-0028](adr/00028-flat-rate-pricing.md) — allocation-priced, not
  usage-metered).
- **Pricing is per-datencenter.** Instances pay based on the actual
  server costs of the region they run in — a Nuremberg customer never
  subsidizes Singapore. Generalization rule: each region's **fleet cost
  is a pool** — a region's price floor scales with the SUM of its
  server costs, however many boxes that turns out to be.
- **Rolling rates are the floor** the business must clear; term
  discounts are margin, not a dependency.
- **Fleet plan: ONE Nuremberg box as long as demand allows** — legacy
  €21.61 contract now, €87/mo rolling at renewal (€64/mo on 24-month
  terms — the actual-spend note). Singapore is a **contingent
  extension** (own floor €101/mo rolling; trigger: the Thalmyra
  playtest latency need), not an assumed day-one cost.

**Dependency, stated plainly**: the density model below assumes the
**scale-to-zero + wake-on-use platform lane** (being filed separately)
ships **before production charging**. Until it does, pods run always-on
and the dedicated-density math applies (interim numbers in the finding
below). Pricing per this proposal is coupled to that lane.

**Billing framing**: prices are **monthly-equivalent rates**; billing
accrues **micro-cents per microsecond** of elapsed time against the
wallet (`perform_settle`'s µs math, #153) — mid-month deploys bill
mid-month, and scale-to-zero idling does not reduce the running rate.

## TL;DR

Under the oversubscription model the per-box ceiling is **storage**
(~46 `small` instances), not CPU — the multiplier needed for cost-cover
collapses. On the renewal floor (€87/mo rolling):

- **A′ — ×1.5 margin headroom**: `small` $4.19/mo; full bill covered
  at 63% fill (29/46) — the #125 calibration's headroom shape; 1.5×
  the anchor.
- **B′ — ×1.2 B-lite (recommended)**: `small` $3.35/mo; full bill
  covered at 78% fill (36/46); 1.2× the anchor.
- **C — hold the anchor (×1.0)**: `small` $2.79/mo; covered only
  near-full (43/46 = 93%); **never** covers Singapore's floor.

The earlier draft of this proposal (×1.8/×2.4) modeled dedicated
always-on resources — superseded by the owner's product clarification;
the needed lift roughly halves or better. Zero paying customers today
(charges gated on the VAT registrations,
[ADR-0029](adr/00029-payments-adapter-selfmor.md) Am. 3) — repricing
now is grandfathering-free.

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
| R2 (WAL-G backups, [ADR-0009](adr/00009-single-cnpg-cluster.md)) | — | <0.50 | — | fixed | assumption: platform DBs only; customer PVCs have no R2 path |
| Bitwarden SM (operator machine accounts, [ADR-0021](adr/00021-secrets-bws-operator.md)) | — | ~4.00 | — | fixed | assumption: Teams-plan floor |
| Grafana Cloud free, Cloudflare free | — | 0 | — | fixed | verified ([ADR-0012](adr/00012-observability-grafana-cloud.md), [architecture.md](architecture.md)) |
| HitPay fees | — | — | — | excluded | not live until the VAT gates clear (ADR-0029 Am. 3/4) |

Nuremberg pool (server + $6.20 platform extras; +$15 Postmark on
"full"): **renewal floor $103.64 lean / $118.64 full**; **legacy,
until renewal: $30.40 / $45.40**. On 24-month terms the renewal box
actually spends $77.88 / $92.88 — a ~$26/mo cushion the pricing must
not depend on. Marginal cost per **idling** instance is ~storage-only
(pods at 0), which is the entire economics of the model; per-instance
variable cost is otherwise ~$0.

## Density per box (oversubscription model)

The ceiling is **storage**: ~460 usable GB of 512
([pricing-calibration.md](pricing-calibration.md)'s own figure). CPU
and RAM govern the **active set** only: N · r · cpu ≤ 12 cores and
N · r · ram ≤ ~24 GB at active ratio r. At r ≤ 50% storage binds for
every seeded size:

| Size (cpu / RAM / disk) | Capacity (storage-bound) | Active set @ r=50% |
|---|---|---|
| micro (0.25 / 512 MB / 5) | 92 | 11.5c / 23 GB ✓ |
| small (0.5 / 512 MB / 10) | **46** | 11.5c / 12 GB ✓ |
| medium (0.5 / 1 GB / 10) | 46 | 11.5c / 23 GB ✓ |
| standard (1 / 2 GB / 20) | 23 | 11.5c / 23 GB ✓ |
| plus (2 / 4 GB / 50) | 9 | 9c / 18 GB ✓ |
| pro (4 / 8 GB / 100) | 4 | 8c / 16 GB ✓ |

- Above r ≈ 52% the CPU-active ceiling (24/r smalls) replaces storage
  as the cap — see the active-ratio sensitivity table.
- r is a product parameter the scale-to-zero lane owns; pricing
  assumes it stays ≤ ~50% (the wake-latency product tuning decides the
  exact idle threshold).

Planned-fill basis throughout: every instance at `small` — the shape
the catalog sells (both apps recommend it). Under storage-bound
capacity this is **not** a worst case — see the mix table in the
finding below.

## The finding, restated under the correct model

| Basis (`small` fill) | Max-fill revenue (current prices) | Break-even | Verdict |
|---|---|---|---|
| Renewal floor, lane shipped (cap 46) | 46 × $2.79 = $128.34 | 38 lean / 43 full | **covered at full fill** (+19%/+8%) — but only at 83–93% fill |
| Renewal floor, lane NOT shipped (cap 24, always-on pods) | 24 × $2.79 = $66.96 | 43 full | underwater at any of these prices — ×1.2: $80.40, ×1.5: $100.56; only the earlier draft's ×1.8 covers ($120.72) |
| Legacy pool (today, either cap) | — | 11–17 | comfortably covered — the cushion that expires with the contract |

So the honest statement flips from the earlier draft: today's prices
CAN cover the renewal floor — but only with the box ~83–93% storage-
full, leaving no cushion for churn, and never covering Singapore
(BE-full 49 > 46). A modest multiplier buys the cushion; the dedicated-
density draft's ×1.8–×2.4 was an artifact of modeling always-on pods.

**Revenue by fill mix — `small` is the plan, not the worst case.**
Storage is now the binding resource, and the anchor's sublinear curve
prices big sizes cheap per GB (revenue per 10 GB: micro $4.72, small
$2.79, medium $3.41, standard $2.59, plus $1.66, pro $1.34). A
big-size-heavy box dilutes revenue (at ×1.0; relatives don't move
with the multiplier):

| Fill mix (at cap) | Revenue | vs full pool $118.64 |
|---|---|---|
| all-medium (46) | $156.86 | +32% |
| all-small (46) | $128.34 | +8% |
| all-standard (23) | $119.14 | ~break-even |
| all-plus (9) | $74.70 | −37% |
| all-pro (4) | $53.56 | −55% |

The options below are computed on the sold shape (all-`small`); an
all-`pro` box never covers (at B′ ×1.2: $64.24, −46%). Mitigation is
catalog reality — big sizes are unwritten future apps and customs —
plus an explicit revisit trigger: **the first `plus`/`pro`-shaped
catalog app reopens big-size relative pricing** (the anchor's
sublinearity vs linear storage cost).

## Options (baseline: one Nuremberg box, lane assumed)

Every option is a **uniform surcharge m on the curve constants** (the
v4 curve ×m — "curve v5": exponents, rounding, stopped-fee semantics,
wizard UX, below-recommendation ack, and the #121 snapshot/grace all
unchanged). Prices are the curve's exact half-up cents at each
allocation. Fill percentages are of the 46-small storage cap.

### Option A′ — margin headroom (×1.5)

**Definition**: restores the #125 calibration's shape — break-even at
~54–63% of capacity instead of 93%. `small` = $4.19.

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 3.53 | 30 |
| small | 4.19 | 51 |
| medium | 5.12 | 51 |
| standard | 7.76 | 85 |
| plus | 12.46 | 169 |
| pro | 20.08 | 285 |

Break-even (`small`): 25 lean / 29 full of 46 (54% / 63%). Margin,
all-`small` fill (basis $103.64 lean / $118.64 full):

| Fill | Revenue | vs lean | vs full |
|---|---|---|---|
| 50% (23) | $96.37 | −8% | −23% |
| 70% (32) | $134.08 | +23% | +12% |
| 85% (39) | $163.41 | +37% | +27% |
| 100% (46) | $192.74 | +46% | +38% |

Market position: 1.5× the reference host.

### Option B′ — B-lite (×1.2) — **recommended**

**Definition**: full rolling bill covered at 78% fill (36 of 46) with
margin building beyond — a real cushion without leaving the anchor's
neighborhood. `small` = $3.35.

| slug | $/mo | stopped ¢/mo |
|---|---|---|
| micro | 2.83 | 24 |
| small | 3.35 | 40 |
| medium | 4.09 | 40 |
| standard | 6.21 | 68 |
| plus | 9.96 | 135 |
| pro | 16.06 | 228 |

Break-even (`small`): 31 lean / 36 full of 46 (67% / 78%). Margin:

| Fill | Revenue | vs lean | vs full |
|---|---|---|---|
| 50% (23) | $77.05 | −35% | −54% |
| 70% (32) | $107.20 | +3% | −11% |
| 85% (39) | $130.65 | +21% | +9% |
| 100% (46) | $154.10 | +33% | +23% |

**Interim cushions**: the legacy pool makes B′ cash-positive from ~10
smalls (+9% lean at 10, +55% at 20); on 24-month terms the renewal box
at cap runs ~+40% full. Market position: 1.2× the reference host —
the premium is curation + zero-ops + wake-on-use, not dedicated
hardware.

### Option C — hold the anchor (×1.0, no change)

Prices stay as shipped (`small` $2.79). Covered only near-full: 38
lean (83%) / 43 full (93%) of 46; margins −9% full at 85% fill, +8% at
cap. **Singapore never covers at C** (BE-full 49 > 46 cap). Burn =
pool − revenue, stated positive (`small` fill, renewal floor): 5
smalls $89.69/$104.69 lean/full; 10: $75.74/$90.74; 32: $14.36/$29.36.
Raise on a trigger, not a date: production charges enabled (the VAT
gates), 30 smalls running, or the renewal/box decision.

### Break-even as f(multiplier, active-ratio)

Capacity = min(46 storage, floor(24/r) CPU-active) smalls. At the
scenarios 20/35/50% storage binds (cap 46 for all three); the ratio
bites above ~52%. Per option (EU renewal floor, full basis):

| Option (m) | BE-full | BE as % of cap (r ≤ 50%) | Max r still covering full at cap |
|---|---|---|---|
| C ×1.0 | 43/46 | 93% | ≤55% |
| B′ ×1.2 | 36/46 | 78% | ≤66% |
| A′ ×1.5 | 29/46 | 63% | ≤82% |

(e.g. at r = 60% the cap drops to 40: C can no longer cover full at
cap; B′ still does — 40 × $3.35 = $134.00 = +11%.)

## The Singapore extension (contingent)

**Trigger** (owner): the Thalmyra playtest latency need for PH
players. **Floor**: RS 4000 G12.5 at €101/mo rolling (€75 24-mo) —
premium baked in. SG pool: $119.32 lean / $134.32 full; same hardware
⇒ same 46-small cap. Same option definitions on the SG floor —
derivations: A′-SG (63% fill): ×1.7; B′-SG (85% fill): ×1.25:

| slug | A′-SG $/mo | A′-SG ¢ stopped | B′-SG $/mo | B′-SG ¢ stopped |
|---|---|---|---|---|
| micro | 4.00 | 34 | 2.94 | 25 |
| small | 4.75 | 57 | 3.49 | 42 |
| medium | 5.80 | 57 | 4.27 | 42 |
| standard | 8.80 | 96 | 6.47 | 71 |
| plus | 14.12 | 192 | 10.38 | 141 |
| pro | 22.76 | 323 | 16.73 | 237 |

Break-even (`small`): A′-SG 26 lean / 29 full (57%/63%); B′-SG 35
lean / 39 full (76%/85%). B′-SG margins at 50/70/85/100%: −49/−7/
+12/+26 lean, −67/−20/+1/+16 full. At C-SG: BE-full 49 > 46 — **hold-
the-anchor never covers Singapore's floor**. Thalmyra co-tenancy
shares the box's real bill (attribution = owner call); the tables
price FluxVale against the full SG pool, conservative.

## The headroom sub-decision (region growth past one box)

The pooling rule is what happens when a region outgrows one box: its
price floor rises to the new fleet sum (capacity scales too — N boxes
⇒ N×46 smalls storage). Treatments, decided now as policy:

- **(a) Price for planned capacity**: prices set to the post-expansion
  pool at post-expansion density — lower per-instance, underwater
  until the fleet ~fills.
- **(b) Margin absorbs the underutilization temporarily (recommended)**:
  per-box pricing stands; the new box's ramp eats margin until its
  fill catches up. Govern: order the next box at ~85% fill of the
  current one; check region revenue ≥ region server-sum quarterly.

## Timing — the zero-customers window

Production charges are gated on the [ADR-0029](adr/00029-payments-adapter-selfmor.md)
Am. 3 registrations, so there are zero paying customers today. **A
change now touches nobody.** (Any beta instances ride welcome credits
and hold their creation-time snapshot anyway; instance count isn't
verifiable from this repo — assumption.)

Waiting until after first customers: new instances price live
immediately; existing ones hold creation-time cents up to 12 months
(#121's grace) — cost of waiting ≈ (new − old) × instances × average
remaining grace, plus post-launch-rise optics. One sequencing
requirement cuts the other way: **the scale-to-zero lane must land
before production charging for ANY option below to be viable** —
pre-lane the cap is 24 and even A′ runs −18% full at cap (B′ −48%,
C −77%); the only pre-lane self-sufficient level is the earlier
draft's ×1.8. The VAT gates are the natural synchronization point.

## Interplay kept coherent (all options)

- **Stopped fee** scales with m: `small` stopped $0.34 (C) / $0.40
  (B′) / $0.51 (A′) baseline; $0.42 (B′-SG) / $0.57 (A′-SG). Scale-to-
  zero **idle** is not stopped — the running rate keeps accruing
  monthly-equivalent, µs-billed.
- **Welcome credits ($3)**: runs a `small` 32 days (C) / 27 (B′) / 21
  (A′) — and months while stopped/idled.
- **Below-recommendation ack + floors**: unchanged. A half-`small`
  custom (0.25 cpu / 256 MB / 5 GB) prices $2.00 (C) / $2.40 (B′) /
  $3.00 (A′) — curve-continuous; the wizard's live estimate remains
  the charge by construction (#186).
- **Reproduction guarantee** (as implemented, #206): the regional
  surcharge map in `PriceAllocation` and the `pricing_data.yaml`
  cents change in one PR — plus the doc-table literals in
  `pricing_data_test.exs` / `pricing_seed_test.exs` and the
  calculator-point assertion in `price_allocation_test.exs` (0.25
  cpu / 0.25 GB / 0 GB: 180¢ → 216¢ at B′, 270¢ at A′) — the YAML
  equals the curve at every size by construction. The v4 constants
  themselves are untouched (ADR-0028 Am. 2).

## Implementation lanes (out of scope here — flagged)

- **Scale-to-zero + wake-on-use** (filed separately): this proposal's
  density model and the B′/C options **assume it ships before
  production charging**.
- **Region dimension on prices**: the Cluster registry already keys
  routing by region (v1's ResolveClusterFromRegion,
  [ADR-0006](adr/00006-single-cluster-multi-region-ready.md)); the
  curve gains a region parameter and the wizard's live estimate
  (#184) + creation-time snapshot (#121) record region + price
  together. Until an SG box exists, one region row ships.

## Recommendation

**B′ (×1.2) on the one-box baseline — B′-SG (×1.25) as the contingent
extension — with treatment (b) on growth and the 85%-fill box-add
trigger.**

1. Full rolling bill covered at 78% fill with margin building beyond
   (+23% full at cap) — a real churn cushion, not the 93%-fill
   knife-edge C runs on.
2. 1.2× the reference host keeps the entry story intact while the
   product is unproven; the premium is the zero-ops curation +
   wake-on-use convenience, honestly priced.
3. The legacy pool cushions the pre-renewal months (+9% lean at just
   10 smalls); prices never step up at renewal.
4. C's failure mode is structural, not marginal: it never covers
   Singapore's floor and tolerates only ≤55% active ratio. A′ is the
   fallback if the owner wants #125's headroom restored (63% fill
   cover) and can carry 1.5×.
5. Sequencing: the scale-to-zero lane must precede production
   charging; the VAT gates are the natural sync point.

Rejected variants: a CPU-term-only reshape and a global curve with an
SG surcharge line-item (as before); also ×0.95 — the pure
"self-sufficient at 100% fill" floor prices below the market anchor
and buys zero cushion.

**Decision (2026-10-22, #200)**: **B′ (×1.2)** on the one-box
baseline — B′-SG (×1.25) as the contingent extension — with treatment
**(b)** on growth (the 85%-fill box-add trigger is margin-absorbed:
operational stance, not code). Implemented on #206.
