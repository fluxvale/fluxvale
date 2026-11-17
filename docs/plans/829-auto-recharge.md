# Plan: auto-recharge for wallet credits (#829)

**Status**: GO 2026-11-17 — Terence approved via the PA, with one scope
revision: **Polar only** (his provider decision: HitPay is out going
forward, MoR preferred so country-by-country tax compliance is not
ours). D1/D2/D3 decided below. This document is the worker fan-out
spec; the HitPay sunset itself is a separate lane (the existing
adapter module is untouched here).
**Scope**: platform repo only, Polar lane only.

## What the code says today (all read, not guessed)

- The adapter ([ADR-0029](../adr/00029-payments-adapter-selfmor.md)):
  `FluxVale.Billing.PaymentProvider` — `create_checkout/2`,
  `verify_webhook/2`, `fetch_payment/1`
  (`apps/platform/lib/flux_vale/contexts/billing/payment_provider.ex`).
  Two implementations: `Providers.HitPay` and `Providers.Polar`.
  **Polar is the active default** (`config.exs` →
  `payments_provider: Providers.Polar`, flipped in #390, 2026-11-06;
  `PAYMENTS_PROVIDER` env can still name HitPay per env; OQ #4:
  "HitPay remains the adapter's dormant second implementation").
- A top-up is a `Topup` row (`status: pending/completed/failed/expired`,
  net `amount_cents` + `tax_cents`, buyer-evidence fields) charged the
  gross (net + VAT); `StartTopup` resolves the rate authoritatively and
  enforces the $5 floor (`FluxVale.Billing.min_topup_cents/0`).
  `CompleteTopup` is the ONE credit path: idempotency key
  `<provider>:<payment_id>`, gross guard, terminal-once status write.
- The zero-balance ladder (#124/#133): `SweepZeroBalance` walks every
  wallet hourly (`Workers.ZeroBalanceSweep`, Oban `:billing`, cron
  `7 * * * *`) under the wallet advisory lock (`WalletLock`) — runway
  warning < 24h, auto-stop at ≤ 0, destroy clock at < 0 (+30d,
  T-7/T-1). Mails ride inside the transaction; out-of-DB effects run
  after commit (`suspend_gateways` pattern). ExpireStaleTopups (#364)
  flips rows `:pending` > 24h to `:expired`, terminal-once; a late
  verified payment still credits (CompleteTopup's widened guard).
- Webhooks: per-provider routes, constant-time HMAC verify, 200-ack
  discipline (`Webhooks.HitPayController`, `Webhooks.PolarController`).
- The wizard (`BillingLive.Topup`) renders the provider by name and
  mounts on personal + org routes; any member may top up ("money in").
- Money: integer cents everywhere; the wallet balance is a live `sum`
  aggregate over `LedgerEntry` (never a column); settles serialize on
  `WalletLock` with a fresh re-read (the `PerformSettle` discipline).

## Provider capability — the research answer

Both providers CAN save a method and charge it off-session. Primary
sources, read 2026-11-17 (docs.hitpayapp.com, polar.sh/docs, Polar's
published 2026-10 OpenAPI).

**HitPay** (excluded from this lane by the owner's decision — recorded
for the archive; nothing in the slices touches it):

- Save Payment Method API: `POST /v1/recurring-billing` with
  `save_payment_method=true` → hosted page → customer attaches a
  method. Later charges: `POST /v1/charge/recurring-billing/{id}` with
  `amount` + `currency` — **variable amount, merchant-initiated,
  synchronous** (`payment_id`, `status: "succeeded"`). "You can charge
  different amounts each time."
- PH merchant accounts (ours) support recurring: **Cards, ShopeePay,
  TnG, ZaloPay, GCash** — GCash is fixed-cycle only (no save-method).
  No auth-and-hold. **No idempotency parameter is documented on the
  charge API** — a design constraint, not a blocker (below).
- Events: `charge.created`, `recurring_billing.method_attached` /
  `method_detached`, `subscription_updated`; same HMAC-SHA256 salt
  scheme as today's payment-request webhooks.
- Sandbox vs production: separate base URLs
  (`api.sandbox.hit-pay.com` / `api.hit-pay.com`), separate API keys
  and webhook salts (their FAQ/checklist) — the adapter's existing
  `base_url` config shape already covers it.

**Polar** (the active lane):

- Customers + payment methods: `POST /v1/customers/` (external_id =
  our org id), `POST /v1/customer-sessions/` → `customer_portal_url`
  (pre-authenticated, redirect-only — no JS SDK needed, matching this
  repo's no-Node asset rule), `GET /v1/customers/{id}/payment-methods`.
- Off-session charge: `POST /v1/orders/` creates a **draft order
  against a saved payment method** (one-time product; `amount` in
  integer smallest-unit overrides the price; `metadata` rides);
  `POST /v1/orders/{id}/finalize` **synchronously attempts the charge**
  — success → `paid`, failure (decline, missing method, SCA) → stays
  `draft` + 4xx. Webhook `order.paid` fires like today's checkout
  orders.
- **Gate**: "The organization must have the `off_session_charges_enabled`
  feature flag" — a Polar-side org flag. It is **readable over the
  API**: `GET /v1/organizations/{id}` → `feature_settings.
  off_session_charges_enabled` — that read is D1's evidence step
  (below); the flip itself is the owner's dashboard action.

### The honest alternative (fallback, still designed here)

Scheduled attempt + one-click email: the platform emails a pre-filled
top-up link when the threshold trips. UX cost, plainly: it is NOT
zero-touch — the org must open the mail, be signed in, and pay before
the balance hits the stop gate; latency is the inbox, and a missed mail
means stopped instances exactly as today. It ships anyway as the
degrade path (disable notices carry the one-click link), and becomes
the whole feature **only if D1 denies**.

## Decisions

**Settled by the issue**: opt-in per org; threshold + amount + caps;
declines fall through to the existing ladder; same ledger rows as a
manual top-up; every attempt visible to the user and in ops telemetry.

**Settled at GO (2026-11-17, via the PA)**

- **Scope — Polar only.** The owner's provider decision: HitPay is out
  going forward, MoR preferred so country-by-country tax compliance is
  not ours. Auto-recharge targets Polar exclusively; the HitPay
  capability above stays in this doc and ADR-0029 Am. 7 as the
  archived research record. The adapter's provider-agnostic behaviour
  is unchanged (ADR-0029's architecture stands); HitPay simply grows
  nothing — and the adapter's sunset is a separate lane, not this one.
- **D1 — resolved as revised.** Terence flips `off_session_charges_enabled`
  in the Polar dashboard himself (his account; the PA relays the ask).
  **Slice 1's first step is the gating evidence**: a read-only
  production `GET /v1/organizations/{id}` captured with the flag
  visible (`feature_settings.off_session_charges_enabled: true`).
  Nothing downstream builds until that transcript exists in the slice
  PR. If Polar denies the flag: the lane pivots to the reminder-email
  fallback exactly as costed above — no other invariant changes.
- **D2 — ratified as recommended**: threshold 500¢, amount 2500¢
  defaults, 2 auto charges per rolling 24h, 3-strike auto-disable —
  all user-tunable at the setting layer.
- **D3 — ratified**: no saved method at sweep time → skip + one notice
  email; still none on the next pass → disable (`disabled_reason:
  :no_method`).

**Settled here (build on unless the owner objects)**

- **A — the attempt IS a top-up.** Auto-recharge creates `Topup` rows
  (new `origin: :manual | :auto`, additive) and completes through the
  unchanged `CompleteTopup` seam. No second posting path exists to
  keep honest; the invariant "same ledger rows" holds by construction.
- **B — Polar only** (was "Polar first"; upgraded by the GO revision).
  Active provider, MoR tax handling, synchronous finalize,
  redirect-only save-method (portal).
- **C — consent model**: one `AutoRechargeSetting` per org. Writes are
  **owner-role only** (recurring spend consent ≠ "money in"; the
  wizard's any-member stance does not carry). Enable requires a saved
  method + confirmed amount/threshold. Buyer evidence (billing
  country/state, customer type, VAT number) copies from the org's last
  completed top-up as the editable default; the RATE always resolves
  fresh at charge time (#260 discipline — never a copied rate).
- **D — caps**: threshold `threshold_cents` (default 500¢, min 100¢);
  `amount_cents` ≥ the $5 top-up floor (default 2500¢); at most
  **1 in-flight** auto attempt per org; at most **2 auto charges per
  rolling 24h**; **3 consecutive failures auto-disable** the setting
  (email says why + one-click top-up link). Max auto-spend/day =
  2 × amount, shown at enable.
- **E — trigger**: new hourly Oban worker (queue `:billing`, cron
  `23 * * * *`, off :07/:17 and the top of the hour). Per org:
  `WalletLock` → fresh balance read → due? → insert the pending
  `Topup` row → **commit** → charge over HTTP **outside** any
  transaction (the `suspend_gateways` discipline; a network call never
  holds the lock). One POST per attempt, ever: an unknown-outcome
  (timeout) attempt is never re-POSTed — the row stays `:pending`,
  owned by webhooks/`fetch_payment` reconciliation and the 24h stale
  sweep. (The one-POST rule was also the answer to HitPay's
  undocumented charge idempotency; it stays as Polar discipline too —
  the finalize call is the single charge trigger.)
- **F — failure fall-through**: a decline is a `:failed` Topup
  (existing terminal-once guard), counter +1, disable email at 3. The
  ladder is untouched — it keeps its hourly cadence; a successful
  recharge lifts the balance and the ladder clears itself next pass
  (recovery arm already does this). No new wallet states.

## Rejected alternatives

- **Polar subscriptions + metered usage (postpaid)** — replaces the
  prepaid wallet with postpaid billing; breaks the
  ledger-as-source-of-truth stance and the prepaid-credit product
  shape. Not a top-up automation.
- **HitPay-first implementation** — dormant provider; its production
  gates (Am. 3) moved to Polar with the MoR switch (OQ #4). Building
  the dormant lane first doubles the surface before any user benefits.
- **Card data anywhere near us** — both providers vault the method;
  we store provider-scoped references only (same posture as today's
  checkout tokens).
- **Silent scheduled charges without a saved method** — impossible by
  definition; the reminder lane is the honest version and is the
  fallback, not a silent charge.

## Slices

Dependency chain: 1 → 3 → 4; 2 independent of 1; 5 needs 2 (+1 for
the portal button); 6 last. Each slice's tests are its own gate.

### Slice 1 — adapter seam + Polar implementation (+ D1 gating evidence)

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/payment_provider.ex`,
`apps/platform/lib/flux_vale/contexts/billing/providers/polar.ex`,
`apps/platform/test/flux_vale/contexts/billing/providers/polar_test.exs`
(extend). HitPay is NOT touched (owner's Polar-only decision).

**Gating evidence (first, before any code)**: read-only production
API check that the flag is on — `GET /v1/organizations/{id}` with the
org token shows `feature_settings.off_session_charges_enabled: true`.
The transcript (flag line, org id, no token material) goes in the PR
body. If the flag reads false after Terence's flip attempt or Polar
denies it: STOP, report to the architect — the lane pivots to the
reminder fallback.

**Change**: three new OPTIONAL callbacks on the behaviour
(`@callback … | {:error, :unsupported}` via a default
`@optional_callbacks` or explicit default clauses — follow the
existing behaviour's style):

- `create_billing_session/2` — Polar: upsert customer by
  `external_id` (org id), `POST /v1/customer-sessions/` →
  `{:ok, %{customer_id: id, portal_url: url}}`.
- `list_payment_methods/1` — Polar: `GET
  /v1/customers/{id}/payment-methods` → `{:ok, count, default_ref}`
  (we need existence + default, not the instruments).
- `charge_saved_method/3` — Polar: `POST /v1/orders/` (draft; product
  = the existing "FluxVale Credits" product_id config; `amount` =
  integer cents gross; `metadata: %{"topup_id" => reference}`) then
  `POST /v1/orders/{id}/finalize` → `{:ok, %{payment_request_id:
  order_id, payment_id: order_id, amount_cents: n, status: :completed
  | :failed, failure_reason: binary | nil}}`. A finalize 4xx maps to
  `{:ok, …, status: :failed, failure_reason: <code>}` (decline,
  missing method, SCA) — an ANSWERED charge, not an error; transport
  failures stay `{:error, :network_error | :api_error}` (unknown
  outcome — see Decision E).

Amounts integer cents on both sides of the adapter. The callbacks are
optional on the behaviour (default clauses answering `{:error,
:unsupported}`) so the architecture stays provider-agnostic — Polar is
the only implementation (owner's decision); no other provider grows
them in this lane.

**Tests**: Req-stubbed (the existing provider-test pattern): session
create, method list, draft+finalize success, finalize decline (4xx →
`:failed` + reason), transport error.

**Done when**:
`cd apps/platform && mix test test/flux_vale/contexts/billing/providers/`
exits 0 with the new cases (0 failures), and
`mix credo --strict` on the touched files is clean.

### Slice 2 — the `AutoRechargeSetting` resource

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/resources/auto_recharge_setting.ex`
(new; follow `wallet.ex`'s policy/paper-trail/admin posture),
`apps/platform/lib/flux_vale/contexts/billing.ex` (domain delegates),
migration via `mix ash.codegen add_auto_recharge_settings`, tests at
`test/flux_vale/contexts/billing/resources/auto_recharge_setting_test.exs`.

**Shape**: `organization_id` (unique, one per org), `enabled` (bool,
default false), `threshold_cents` (int, ≥ 100), `amount_cents` (int,
≥ `min_topup_cents`), `consecutive_failures` (int, default 0),
`disabled_reason` (`:manual | :declines | :no_method | nil`),
buyer evidence (`billing_country`, `billing_state`, `customer_type`,
`vat_number` — sensitive, mirroring Topup), `provider_customer_id`
(string), `payment_method_status` (`:none | :attached`),
`last_attempt_at`, timestamps. Paper-trail mixin like Wallet's.

**Actions/policies**: `:enable` / `:update` / `:disable` are
owner-role writes (membership `role: :owner` via the org relation —
the wallet's member filter plus the role guard); members read.
System actions (`:record_attempt_outcome`, `:disable_with_reason`,
`:set_method_status`) run `authorize?: false`, actor-forbidden by
policy (the wallet's `set_carryover` shape).

**Tests**: policy matrix (member cannot enable, owner can, system
writes actor-forbidden), attribute constraints, uniqueness.

**Done when**: `mix test test/flux_vale/contexts/billing/` green
(includes the new file) and `mix ash.codegen --check` clean.

### Slice 3 — `StartAutoRecharge` operation + webhook arm

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/operations/start_auto_recharge.ex`
(new), `.../operations/start_topup.ex` (extract ONLY the shared tax
resolution/guard block into a private-sharable form or a small
`Billing.TaxQuote` helper — do not duplicate the rate logic),
`apps/platform/lib/flux_vale_web/controllers/webhooks/polar_controller.ex`
(order.paid arm: accept order-id payloads — resolve by
`metadata.topup_id` first, then `payment_request_id` == order id;
idempotency key `polar:<order_id>`), `billing.ex` delegates, tests
mirroring `start_topup_test.exs` + `polar_controller` tests.

**Behavior**: `call(org, setting, opts)` — under `WalletLock` +
fresh balance read (caller = sweep) already done, this operation:
(1) builds the `Topup` (origin `:auto`, net = setting.amount_cents,
tax = fresh `Tax.tax_cents(net, resolved_rate(setting evidence))`,
buyer fields from the evidence), persists `:pending`; (2) AFTER
commit, `charge_saved_method` with gross = net + tax; (3) sync
`:completed` → nothing more (webhook/reconcile posts the credit —
never the starter); sync `:failed` → `mark_failed` +
`record_attempt_outcome`; `{:error, :network_error | :api_error}` →
row stays `:pending`, outcome recorded as attempt-started only.
Amount guard: CompleteTopup's gross check applies unchanged (the
order `subtotal_amount` must equal gross — verify in Slice 1 sandbox
evidence that Create Order's `amount` maps to `subtotal_amount` the
way checkout amounts do; if Polar maps it differently, adjust the
mapping here, never the guard).

**Tests**: happy path (row pending → charge completed → webhook
completes + credits once, idempotent replay), decline path (failed
row + counter), timeout path (row stays pending, no second POST —
assert one HTTP call), tax resolution fresh-from-table, webhook
order-id resolution by metadata then by payment_request_id.

**Done when**: the new operation + controller tests green
(`mix test test/flux_vale/contexts/billing/operations/start_auto_recharge_test.exs
test/flux_vale_web/controllers/webhooks/` — 0 failures).

### Slice 4 — `RechargeSweep` worker + caps + auto-disable

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/operations/sweep_auto_recharge.ex`
(new), `apps/platform/lib/flux_vale/workers/recharge_sweep.ex` (new,
`use Oban.Worker, queue: :billing, max_attempts: 3` — the
`ZeroBalanceSweep` plumbing shape), `config/config.exs` (cron
`23 * * * *` with the stagger comment), `mailer.ex` +
`topup_outcome_mail.ex` (disable notice), tests.

**Behavior**: for each org with an enabled setting, in per-org
isolation (`safe_sweep` rescue pattern): under `WalletLock`, re-read
balance; due = `balance < threshold_cents` AND no `:pending` auto
top-up exists AND auto charges in the last 24h < 2 AND a payment
method exists (`list_payment_methods`; none → notice mail + disable
per D3); if due → `StartAutoRecharge` (which owns the top-up row).
On a failed outcome: increment `consecutive_failures`; at 3 →
`disable_with_reason(:declines)` + mail with a one-click top-up URL
(`~p"/billing/topup"` or the org route). A successful outcome resets
the counter. One wallet's failure never blocks the rest; job fails
after the loop so Oban retries (the ZeroBalanceSweep stance).

**Tests**: due/not-due matrix, in-flight guard, 24h cap, 3-strike
disable + mail, no-method disable (D3), counter reset on success,
per-org isolation.

**Done when**: `mix test test/flux_vale/workers/recharge_sweep_test.exs
test/flux_vale/contexts/billing/operations/sweep_auto_recharge_test.exs`
green (0 failures).

### Slice 5 — billing UI: the auto-recharge card

**Files**:
`apps/platform/lib/flux_vale_web/live/org_live/billing.ex` (+ the
personal billing surface it shares shape with),
`apps/platform/lib/flux_vale_web/components/billing_components.ex`,
LiveView tests beside the existing ones.

**Behavior**: a card between the balance band and the ledger: state
(off / armed with threshold/amount/next-cap math), the saved-method
status, and for owners: enable/disable, threshold+amount form
(validated server-side against Slice 2's constraints), "Add payment
method" (LiveView event → `create_billing_session` → external
redirect to `customer_portal_url` — fresh per click, never stored),
attempt history = existing top-up rows filtered `origin: :auto`
(badge "Auto" on those rows wherever top-ups render). All capture
rules apply at PR time (this is a user-visible surface: screenshots,
light+dark).

**Tests**: render states per role (member sees, owner edits),
form validation, redirect event, origin badge.

**Done when**: `mix test test/flux_vale_web/live/org_live/billing_test.exs`
(and the personal-surface file) green with the new cases.

### Slice 6 — telemetry + docs

**Files**: `apps/platform/lib/flux_vale/prom_ex.ex` (attempt counter
by outcome — org id as label ONLY, no amounts),
`complete_topup.ex` (PostHog "wallet topped up" gains an
`origin` prop; still no amounts — the ADR-0049 posture),
`docs/public/billing/auto-recharge.md` (new; what it does, the caps,
how to disable, the failure ladder promise), this plan's Verification
section updated.

**Done when**: `mix ci` green overall (the PR gate below) and
`mix docs.lint`/`blog.lint` clean.

## ADR amendment

Lands in THIS plan PR (billing-semantics change → yes, it warrants
one): [ADR-0029](../adr/00029-payments-adapter-selfmor.md)
Amendment 7 — saved methods + off-session charges join the adapter;
attempt-is-a-top-up; consent/caps; HitPay capability recorded so the
dormant-lane wake is a module. Index row updated to Amendments 1–7.

## Overall PR gate

Implementation PRs (not this one): `cd apps/platform && mix ci` —
all aliases green at 100% coverage (#86 discipline). PR titles
`feat(platform): …` per slice or one PR per the owner's call at GO;
`Closes #829` only on the PR that completes the feature.

## Verification status

- Code citations: read on this branch (`e8b8fcc8`), files named above.
- Provider facts: HitPay docs (save-payment-method, charge-saved-card
  OpenAPI, availability-by-market PH row, sandbox guide) and Polar
  2026-10 OpenAPI (`/v1/orders/`, `/v1/orders/{id}/finalize`,
  customer-sessions, customers, payment-methods) — fetched 2026-11-17,
  quotes in this file are from those pages.
- NOT verified (cannot be, from this repo): the production org's
  `off_session_charges_enabled` state until Slice 1's evidence read
  (Terence flips it in the Polar dashboard — PA relays in parallel);
  Create Order `amount`→`subtotal_amount` mapping behavior in a live
  sandbox call (Slice 1 must capture a sandbox transcript as PR
  evidence); the customer-portal save flow's exact return UX (staging
  e2e).
