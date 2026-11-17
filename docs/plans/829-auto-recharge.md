# Plan: auto-recharge for wallet credits (#829)

**Status**: GO 2026-11-17 (Terence, via the PA), amended same day by
his sequencing decision: **launch ships the reminder lane** (low
balance → email with a one-click top-up link, Polar-only); the
off-session charge lane is **built ready but staged behind a Polar
Pro plan upgrade that happens only after launch** — activation is a
config flip plus the API evidence check (Slice S6). Polar-only
throughout (his provider decision: HitPay out going forward, MoR
preferred). This document is the worker fan-out spec; the HitPay
sunset is a separate lane (the adapter module is untouched here).

**Scope**: platform repo only, Polar lane only, two waves: **L
(launch)** and **S (staged, inert until activation)**.

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
  integer smallest-unit overrides the price; `metadata` rides; the
  customer must carry a **complete billing address** — Polar computes
  tax from it — and at least one saved method); `POST
  /v1/orders/{id}/finalize` **synchronously attempts the charge** —
  success → `paid` (Polar emails the buyer their own confirmation;
  `order.paid` webhook fires), failure → 4xx with the order reverted
  to `draft` (`402` decline/no-method/SCA; `403` off-session not
  enabled for the org; `412` not draft). A failed finalize leaves a
  re-finalizable draft — our discipline never re-drives it (Decision
  E).
- **Gate — preview + PAID-PLAN-ONLY** (polar.sh/docs/features/orders +
  the fees page, read 2026-11-17): "Off-session charges are currently
  in preview. You'll only be able to run off-session charges if you
  are on a paid plan." Pro is $20/mo at 3.8% + 40¢ (Growth $100,
  Scale $400; Starter cannot run them). The org flag
  (`feature_settings.off_session_charges_enabled`, readable via
  `GET /v1/organizations/{id}`) unlocks with the plan upgrade, not a
  dashboard toggle. Our org post-dates Polar's May 27 2026 Early
  Member cutoff — there is no grandfathered rate to lose by upgrading
  later.

## The two lanes

**Launch lane — the reminder** (ships now): when the wallet dips
below the org's threshold, the platform emails the org's members a
one-click, amount-prefilled top-up link. No stored credentials, no
off-session API, nothing the Starter plan can't run. UX cost, stated
plainly: it is NOT zero-touch — the org must open the mail, be signed
in, and pay before the balance hits the stop gate; latency is the
inbox, and a missed mail means stopped instances exactly as today
(the ladder's own < 24h runway warning still fires independently
beneath it).

**Staged lane — the off-session charge** (built ready, inert until
activation): the saved-method design below, everything behind a
platform config gate (`charge_mode`, default false). Activation =
Terence upgrades the Polar org to Pro after launch → flip
`AUTO_RECHARGE_CHARGE_MODE` → run the evidence check (Slice S6).
Nothing in Wave S gates launch; nothing in Wave L knows about Wave S
beyond the shared setting row.

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
- **D1 — superseded by the sequencing decision.** Off-session charges
  are preview + paid-plan-only on Polar (facts above). Terence WILL
  subscribe to Pro ($20/mo) but ONLY AFTER LAUNCH. Therefore:
  **launch scope = the reminder lane**; the charge lane stages behind
  the upgrade, structured so activation is a config flip plus the
  evidence check (`GET /v1/organizations/{id}` showing the flag true —
  Slice S6). The flag requirement is quoted from the Create Order
  endpoint's own description; pre-upgrade, the honest runtime shape is
  finalize's `403`.
- **D2 — ratified as recommended, all four owner-tunable** (staged
  lane): threshold 500¢, amount 2500¢, 2 auto charges per rolling 24h,
  3-strike auto-disable — each an attribute on the setting with
  bounded ranges (see Slice S2); the "max auto-spend/day = daily cap ×
  amount" line shown at enable recomputes from the stored values.
  The launch lane inherits threshold + amount with the same defaults;
  its cadence (at most one reminder per 24h per episode) is fixed,
  not a dial — revisit on the first complaint about mailbox fatigue.
- **D3 — ratified** (staged lane): no saved method at sweep time →
  skip + one notice email (persisted marker `no_method_notified_at`);
  still none on the next pass → disable (`disabled_reason:
  :no_method`).
- **Sequencing** (Terence, 2026-11-17): Wave L is the launch gate —
  nothing requiring off-session capability may block it. Wave S builds
  ready and stays inert. The activation slice (S6) is blocked on the
  owner's Pro upgrade — an external event, not a code dependency.

**Settled here (build on unless the owner objects)**

- **G — the shared setting, two consent levels.** One
  `AutoRechargeSetting` row per org carries both lanes. At launch:
  `mode: :off | :reminder` (owner-role writes). The staged lane adds
  `:auto` — arming it is its OWN explicit owner consent (saved method
  + confirmed charge settings), never implied by a reminder opt-in:
  an org that asked for emails must never be silently charged the day
  the config gate flips. Launch lane reminder rules: fire when
  `balance < threshold_cents` and `last_reminded_at` is older than
  24h (or nil); clear the marker when balance recovers ≥ threshold
  (episode semantics, the ladder-warning shape).
- **A — the attempt IS a top-up** (staged lane). Auto-recharge
  creates `Topup` rows (new `origin: :manual | :auto`, additive) and
  completes through the unchanged `CompleteTopup` seam. No second
  posting path exists to keep honest; the invariant "same ledger
  rows" holds by construction. The launch lane creates NO top-up
  rows — the top-up it produces is an ordinary manual one through
  the wizard.
- **B — Polar only** (was "Polar first"; upgraded by the GO revision).
  Active provider, MoR tax handling, synchronous finalize,
  redirect-only save-method (portal).
- **C — consent model** (staged lane): writes are **owner-role only**
  (recurring spend consent ≠ "money in"; the wizard's any-member
  stance does not carry). Arming `:auto` requires a saved method +
  confirmed amount/threshold/caps. Buyer evidence (billing country/
  state, customer type, VAT number) copies from the org's last
  completed top-up as the editable default; the RATE always resolves
  fresh at charge time (#260 discipline — never a copied rate).
- **D — caps (threshold/amount serve BOTH lanes; the rest is staged,
  per D2)**: `threshold_cents` (default 500¢, min 100¢) and
  `amount_cents` ≥ the $5 top-up floor (default 2500¢) ship with the
  launch resource; `daily_charge_cap` (default 2, range 1–6) — at
  most that many auto charges per rolling 24h, and at most **1
  in-flight** auto attempt per org (a fixed invariant, not a dial) —
  and `failure_strikes` (default 3, range 2–5) consecutive failures
  auto-disabling the setting (email says why + one-click top-up
  link) arrive with S2. The cap counts CHARGES, not cents — a
  mid-window amount change just changes the next charge's size. The
  enable-time figure shown is GROSS at the org's current rate:
  "max charged/day ≈ cap × (amount + VAT)" (2500¢ amount, 20% VAT,
  cap 2 → up to $60/day charged for $50 of credit).
- **E — trigger** (staged lane): hourly Oban arm on the shared
  RechargeSweep worker (queue `:billing`, cron `23 * * * *`, off
  :07/:13/:17 and the top of the hour — the billing-queue stagger). Per org: `WalletLock` → fresh
  balance read → due? → insert the pending `Topup` row → **commit**
  → charge over HTTP **outside** any transaction (the
  `suspend_gateways` discipline; a network call never holds the
  lock). **The draft order id persists BEFORE the charge trigger**:
  the adapter splits draft creation from finalize (S1), and the row
  records the order id (via the existing `attach_checkout` action)
  between them — so any crash after commit is recoverable, and an
  unknown-outcome attempt is never re-driven: a draft order that was
  never finalized can never charge, so reconciliation may safely
  resolve it. **The sweep reconciles stale `:pending` auto rows**
  (older than 1 hour) before its due-check: `fetch_payment` on the
  persisted order id → paid → complete (idempotent); draft/absent →
  `mark_failed` (nothing can charge) and the next pass may retry.
  A pending row therefore never waits for the 24h stale sweep, and
  local expiry can never free an unresolved charge — the hourly
  reconciliation has already answered it (money landing late still
  credits: CompleteTopup's widened guard, unchanged).
- **F — failure fall-through** (staged lane): a decline is a
  `:failed` Topup (existing terminal-once guard), counter +1,
  disable email at `failure_strikes`. The ladder is untouched — it
  keeps its hourly cadence; a successful recharge lifts the balance
  and the ladder clears itself next pass (recovery arm already does
  this). No new wallet states.

## Rejected alternatives

- **Off-session auto-charge at launch** — requires the Polar Pro plan
  pre-launch; the owner upgrades only post-launch (his sequencing
  decision). Launch waits on no paid plan.
- **Polar subscriptions + metered usage (postpaid)** — replaces the
  prepaid wallet with postpaid billing; breaks the
  ledger-as-source-of-truth stance and the prepaid-credit product
  shape. Not a top-up automation.
- **HitPay-first implementation** — dormant provider; its production
  gates (Am. 3) moved to Polar with the MoR switch (OQ #4). Building
  the dormant lane first doubles the surface before any user benefits.
- **Card data anywhere near us** — the provider vaults the method;
  we store provider-scoped references only (same posture as today's
  checkout tokens).
- **Silent scheduled charges without a saved method** — impossible by
  definition; the reminder lane is the honest version.

## Slices

Two waves. **Wave L (launch)**: L1 → L2 → (L3 ∥ L4). **Wave S
(staged, inert)**: S1 ∥ S2 (S2 after L1 merges — same resource file);
S3 after S1 + S2; S4 after S3 (+L2); S5 after S3 (+L3); **S6 last,
blocked on the owner's Pro upgrade** (external — do not schedule).
Each slice's tests are its own gate. Wave S inertness at launch, by
construction: the config gate (default false) blocks `:auto` writes
(S2) and the sweep's charge arm (S4); the UI renders nothing chargey
gate-off (S5); the S3 webhook arm is inert by resolution-miss —
manual checkout orders carry no `metadata.topup_id` and their
`payment_request_id` is a checkout session id, so the arm no-ops on
every launch-path delivery.

### L1 — the `AutoRechargeSetting` resource (launch shape)

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/resources/auto_recharge_setting.ex`
(new; follow `wallet.ex`'s policy/paper-trail/admin posture),
`apps/platform/lib/flux_vale/contexts/billing.ex` (domain delegates),
migration via `mix ash.codegen add_auto_recharge_settings`, tests at
`test/flux_vale/contexts/billing/resources/auto_recharge_setting_test.exs`.

**Shape (launch only — charge fields arrive with S2)**:
`organization_id` (unique, one per org), `mode`
(`Types.AutoRechargeMode`: `:off | :reminder`, default `:off`),
`threshold_cents` (int, ≥ 100, default 500), `amount_cents` (int,
≥ `min_topup_cents`, default 2500), `last_reminded_at`
(utc_datetime_usec, nil), timestamps. Paper-trail mixin like
Wallet's; AshAdmin read-only (table: org, mode, threshold, amount,
last reminded).

**Actions/policies**: `:set` (owner-role write accepting
mode/threshold/amount; the constraints guard values — a `:reminder`
write with threshold 50¢ fails the attribute constraint); members
read. System action `:record_reminder` (writes `last_reminded_at`,
clears with nil) runs `authorize?: false`, actor-forbidden by policy
(the wallet's `set_carryover` shape).

**Tests**: policy matrix (member cannot set, owner can, system
action actor-forbidden), attribute constraints (threshold floor,
amount floor, mode enum), uniqueness.

**Done when**:
`MIX_TEST_PARTITION=l1 mix test test/flux_vale/contexts/billing/resources/auto_recharge_setting_test.exs`
exits 0 (0 failures) and `mix ash.codegen --check` is clean.

### L2 — the reminder sweep + mail + one-click prefill

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/operations/sweep_auto_recharge.ex`
(new), `apps/platform/lib/flux_vale/workers/recharge_sweep.ex` (new,
`use Oban.Worker, queue: :billing, max_attempts: 3` — the
`ZeroBalanceSweep` plumbing shape), `apps/platform/config/config.exs`
(cron `23 * * * *` with a stagger comment naming the real neighbors:
:07 zero-balance, :13 stranded-instances, :17 stale-topups, plus the
top-of-hour rush) +
`apps/platform/config/runtime.exs` (`RECHARGE_SWEEP_CRONEXPR`
override — the `IDLE_SWEEP_CRONEXPR` precedent, for staging/e2e
compression), `apps/platform/lib/flux_vale/mailer.ex`
(`deliver_auto_recharge_reminder/3`: to, amount_dollars, url —
delivered to the org's members; DUPLICATE the org→members→primary-
verified-address resolution as the sweep operation's own private
helper — `SweepZeroBalance.member_emails/1` is private and the
operation-boundary rule says private helpers are owned, not shared;
follow the pattern, not the function),
`apps/platform/lib/flux_vale_web/live/billing_live/topup.ex` (accept
an `amount` query param — integer dollars, validated ≥
`min_topup_dollars` and ≤ 1000, prefilling the Amount step; must
survive the personal↔org route redirect), tests for all of it.

**Behavior**: for each org with `mode: :reminder`, in per-org
isolation (`safe_sweep` rescue pattern — one bad org is logged and
skipped, job fails after the loop): read the wallet balance (the
live aggregate; NO advisory lock — the reminder writes no wallet
state, so there is nothing to serialize; a balance that moves
mid-read only shifts the reminder by one pass). Below threshold AND
(`last_reminded_at` nil OR > 24h ago) → send the reminder (mail +
`last_reminded_at` write in ONE transaction, the ladder's
marker+mail discipline — a failed send rolls the marker back) to the
org's member emails, linking the org top-up route with
`?amount=<amount_dollars>` (the personal route when the org is the
member's personal org — the wizard redirect must carry the param).
Balance ≥ threshold → clear `last_reminded_at` (episode re-arm).
The reminder copy names the threshold and the one-click amount and
never promises automatic charging.

**Tests**: below-threshold + never reminded → mail + marker (assert
both, atomically); below-threshold + reminded 23h ago → no mail;
recovery clears marker; amount param prefill + validation (below
floor ignored) + redirect survival; per-org isolation.

**Done when**:
`MIX_TEST_PARTITION=l2 mix test test/flux_vale/contexts/billing/operations/sweep_auto_recharge_test.exs test/flux_vale/workers/recharge_sweep_test.exs test/flux_vale_web/live/billing_live/topup_test.exs`
exits 0 (0 failures).

### L3 — billing UI: the auto-recharge card (launch shape)

**Files**:
`apps/platform/lib/flux_vale_web/live/org_live/billing.ex` + the
personal billing surface it shares shape with,
`apps/platform/lib/flux_vale_web/components/billing_components.ex`,
LiveView tests beside the existing ones.

**Behavior**: a card between the balance band and the ledger: state
(off / reminders on, with the threshold and amount shown and "we'll
email your org a one-click top-up link at most once a day while the
balance is below the threshold" copy — no future-feature promises);
for owners: the mode/threshold/amount form (validated server-side
against L1's constraints); for members: read-only. All capture rules
apply at PR time (user-visible surface: screenshots, light+dark,
embedded absolute raw URLs).

**Tests**: render states per role, form validation, enable/disable
events.

**Done when**:
`MIX_TEST_PARTITION=l3 mix test test/flux_vale_web/live/org_live/billing_test.exs`
(and the personal-surface file) exits 0 with the new cases.

### L4 — telemetry + public docs (launch)

**Files**: `apps/platform/lib/flux_vale/prom_ex/plugins/business.ex`
(the business plugin's counter set — NOT `prom_ex.ex`, which is only
the plugin wiring; a reminder counter following that module's
existing `:telemetry` event patterns, NO org-id label — the plugin's
own discipline pins fleet labels to bounded enums with boot-seeded
cardinality; an org-id dimension violates it, so the counter is
labelless), plus the emission call in the L2 sweep operation,
`docs/public/billing/auto-recharge.md` (new; what the reminder does,
threshold/amount, the ≤1/day cadence, how to turn it off, and its
relationship to the ladder warnings), this plan's Verification
section updated.

**Done when**: `mix ci` green overall (the PR gate below) and
`mix docs.lint`/`blog.lint` clean.

### S1 — adapter seam + Polar implementation (staged, no live calls)

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/payment_provider.ex`,
`apps/platform/lib/flux_vale/contexts/billing/providers/polar.ex`,
`apps/platform/test/flux_vale/contexts/billing/providers/polar_test.exs`
(extend). HitPay is NOT touched (owner's Polar-only decision). All
testing is Req-stubbed — **no live Polar calls in this slice** (the
org is on Starter; draft-order creation would 403. The live evidence
is S6's, post-upgrade).

**Change**: four new callbacks on the behaviour, each with a DEFAULT
CLAUSE answering `{:error, :unsupported}` (the behaviour has no
optional-callback precedent — the default-clause form is pinned here;
`@optional_callbacks` is not used):

- `create_billing_session/2` — Polar: upsert customer by
  `external_id` (org id) **carrying a complete billing address from
  the caller's evidence** (Polar requires one on the customer before
  Create Order — it computes tax from it), `POST
  /v1/customer-sessions/` → `{:ok, %{customer_id: id, portal_url:
  url}}`.
- `list_payment_methods/1` — Polar: `GET
  /v1/customers/{id}/payment-methods` → `{:ok, count, default_ref}`
  (we need existence + default, not the instruments).
- `create_draft_charge/3` — Polar: `POST /v1/orders/` (draft; product
  = the existing "FluxVale Credits" product_id config; `amount` =
  integer cents gross; `metadata: %{"topup_id" => reference}`) →
  `{:ok, %{order_id: id, amount_cents: n}}`. Draft creation charges
  nothing; the id it returns is what the caller persists BEFORE any
  charge trigger.
- `finalize_charge/2` — Polar: `POST /v1/orders/{id}/finalize` →
  `{:ok, %{order_id: id, amount_cents: n, status: :completed |
  :failed, failure_reason: binary | nil}}`. A `402`/`403`/`412` maps
  to `{:ok, …, status: :failed, failure_reason: <code>}` — an
  ANSWERED charge, not an error; a failed finalize leaves Polar's
  draft re-finalizable and we never do (Decision E). Transport
  failures stay `{:error, :network_error | :api_error}` (unknown
  outcome — recoverable via the persisted draft id).

Amounts integer cents on both sides of the adapter. The default
clauses keep the architecture provider-agnostic — Polar is the only
implementation (owner's decision).

**Tests**: Req-stubbed (the existing provider-test pattern): session
create (address carried), method list, draft create, draft +
finalize success, finalize decline (402 → `:failed` + reason),
finalize 403 (not enabled → `:failed` + reason), transport error on
each leg.

**Done when**:
`MIX_TEST_PARTITION=s1 mix test test/flux_vale/contexts/billing/providers/`
exits 0 with the new cases (0 failures), and `mix credo --strict`
on the touched files is clean.

### S2 — the setting's charge extension + the config gate (staged)

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/resources/auto_recharge_setting.ex`
(extend), its types file (`AutoRechargeMode` gains `:auto`),
`apps/platform/lib/flux_vale/contexts/billing.ex`
(`auto_recharge_charge_mode?/0`), `apps/platform/config/config.exs`
(`config :flux_vale, :auto_recharge, charge_mode: false`) +
`apps/platform/config/runtime.exs` (`AUTO_RECHARGE_CHARGE_MODE`
env override, whitelist map — the `PAYMENTS_PROVIDER` shape),
migration via `mix ash.codegen extend_auto_recharge_settings_for_charge`,
tests.

**Change**: widen `mode` to `:off | :reminder | :auto`; add
`daily_charge_cap` (1–6, default 2), `failure_strikes` (2–5,
default 3), `consecutive_failures` (default 0), `disabled_reason`
(`:manual | :declines | :no_method | nil`), `no_method_notified_at`,
buyer evidence (`billing_country`, `billing_state`, `customer_type`,
`vat_number` — sensitive, mirroring Topup), `provider_customer_id`
(string), `payment_method_status` (`:none | :attached`),
`last_attempt_at`. The `:set` action REJECTS `mode: :auto` unless
`Billing.auto_recharge_charge_mode?/0` (a validation, not a policy —
the gate is platform state, not actor identity). System actions:
`:record_attempt_outcome`, `:disable_with_reason`,
`:set_method_status` (`authorize?: false`, actor-forbidden).

**Tests**: `:auto` rejected with the gate false, accepted with it
true (config capture/restore per the test-ownership rule);
constraint matrix for the new attributes; system-action policy
forbids.

**Done when**:
`MIX_TEST_PARTITION=s2 mix test test/flux_vale/contexts/billing/resources/auto_recharge_setting_test.exs`
exits 0 (0 failures) and `mix ash.codegen --check` is clean.

### S3 — `StartAutoRecharge` operation + webhook arm (staged)

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/operations/start_auto_recharge.ex`
(new), `apps/platform/lib/flux_vale/contexts/billing/tax.ex` (extend
with `quote/2` — evidence → `%{rate_bp, tax_cents, reverse_charge?}`
— and refactor `StartTopup` to consume it; `Tax` is the domain helper
module, NOT a shared private helper, per the operation-boundary rule
in `apps/platform/AGENTS.md`; the rate logic must not be duplicated),
`apps/platform/lib/flux_vale/contexts/billing/resources/topup.ex`
(the additive `origin` attribute: `:manual | :auto`, default
`:manual`),
`apps/platform/lib/flux_vale_web/controllers/webhooks/polar_controller.ex`
(order.paid arm: accept order-id payloads — resolve by
`metadata.topup_id` first, then `payment_request_id` == order id;
idempotency key `polar:<order_id>`), `billing.ex` delegates,
`complete_topup.ex` (PostHog "wallet topped up" gains an `origin`
prop; still no amounts — the ADR-0049 posture), tests mirroring
`start_topup_test.exs` + `polar_controller` tests.

**Behavior — load-bearing first**: CompleteTopup's gross guard
applies UNCHANGED — the order's `subtotal_amount` must equal the
gross we sent. S6's evidence transcript must show Create Order's
`amount` maps to `subtotal_amount` the way checkout amounts do; if
Polar maps it differently, the MAPPING adjusts, never the guard.

`call(org, setting, opts)` — under `WalletLock` + fresh balance read
(caller = sweep) already done, this operation: (1) builds the `Topup`
(origin `:auto`, net = setting.amount_cents, tax = fresh
`Tax.quote/2` over the setting's evidence, buyer fields from the
evidence — no buyer email), persists `:pending`; (2) AFTER commit,
`create_draft_charge` (gross = net + tax) and persist the returned
order id via the EXISTING `attach_checkout` action (the row's
`payment_request_id` = order id — reconciliation and the webhook
both key on it); (3) `finalize_charge` on that id; sync `:completed`
→ nothing more (webhook/reconcile posts the credit — never the
starter; Polar emails the buyer their own confirmation); sync
`:failed` → `mark_failed` + `record_attempt_outcome` **in ONE
transaction** (both persist or neither — a crash between them must
not leave an uncounted failure); `{:error, :network_error |
:api_error}` on either leg → row stays `:pending` with whatever
order id persisted (draft leg: nil; finalize leg: the id), and the
sweep's stale-reconciliation arm owns it (Decision E). Outcome
mails: `TopupOutcomeMail` is a structural no-op for auto rows (it
guards on `buyer_email`, which auto rows don't set) — by design; the
user-facing signals are the balance change, the billing page,
Polar's buyer email, and S4's disable notices.

**Tests**: happy path (row pending → draft id attached → finalize
completed → webhook completes + credits once, idempotent replay),
decline path (failed row + counter, atomically), draft-leg transport
error (row pending, NO order id — reconciled to `:failed` by the
sweep's stale arm), finalize-leg transport error (row pending WITH
order id; assert finalize was attempted exactly once and never
re-driven), crash-between-writes (no failed row without its
counter), tax resolution fresh-from-table, webhook order-id
resolution by metadata then by payment_request_id, origin prop on
the analytics event.

**Done when**:
`MIX_TEST_PARTITION=s3 mix test test/flux_vale/contexts/billing/operations/start_auto_recharge_test.exs test/flux_vale_web/controllers/webhooks/`
exits 0 (0 failures).

### S4 — the sweep's charge arm (staged)

**Files**:
`apps/platform/lib/flux_vale/contexts/billing/operations/sweep_auto_recharge.ex`
(extend), `apps/platform/lib/flux_vale/mailer.ex`
(`deliver_auto_recharge_disabled/2` + `deliver_auto_recharge_no_method/1`,
member-emails delivery), tests.

**Behavior**: the sweep grows the `:auto` arm (runs only when
`auto_recharge_charge_mode?/0`). **Stale-pending reconciliation runs
first**, before any due-check (Decision E): every `:pending` auto
top-up older than 1 hour → `fetch_payment` on its persisted order id
(nil id → the draft leg never ran → `mark_failed`) → paid →
`ReconcileTopup` completes it idempotently; draft/absent →
`mark_failed`. Then, per org in `:auto` mode — the payment-method
lookup (`list_payment_methods`) runs BEFORE taking `WalletLock` (a
stalled provider call must never hold the wallet; a method removed
between lookup and charge is answered by finalize's 402 and counted
as a failure like any decline) — under the lock (this arm DOES take
it — it creates top-up rows): re-read balance; due = `balance <
threshold_cents` AND no `:pending` auto top-up exists AND auto
charges in the last 24h < `daily_charge_cap` AND the pre-lock
lookup found a method. No method → D3's two-pass rule:
`no_method_notified_at` nil → notice mail + set it; set and still
none → `disable_with_reason(:no_method)` + mail. If due →
`StartAutoRecharge`. On a failed outcome: increment
`consecutive_failures`; at `failure_strikes` →
`disable_with_reason(:declines)` + mail with a one-click top-up URL.
A successful outcome resets the counter AND clears
`no_method_notified_at`. Reminder-arm behavior is unchanged for
`:reminder` orgs.

**Tests**: due/not-due matrix, in-flight guard, 24h cap (against
`daily_charge_cap`), strikes disable + mail (against
`failure_strikes`), D3's no-method two-pass (notice-then-disable),
stale-pending reconciliation (paid → completed; draft → failed; no
order id → failed), method lookup outside the lock (assert no
provider call while the lock is held — the operation under test
takes the lock only after the lookup), counter reset on success,
gate-off means the arm never runs, per-org isolation.

**Done when**:
`MIX_TEST_PARTITION=s4 mix test test/flux_vale/contexts/billing/operations/sweep_auto_recharge_test.exs test/flux_vale/workers/recharge_sweep_test.exs`
exits 0 (0 failures).

### S5 — the UI's charge card (staged)

**Files**: the L3 surfaces (org + personal billing pages,
billing_components), LiveView tests.

**Behavior**: the card grows its `:auto` presentation, rendered ONLY
when `Billing.auto_recharge_charge_mode?/0` — gate false means the
launch UI, byte-for-byte. Charge state: saved-method status,
threshold/amount/cap/strikes form ("max auto-spend/day =
daily_charge_cap × amount"), "Add payment method" (LiveView event →
`create_billing_session` → external redirect to `customer_portal_url`
— fresh per click, never stored), attempt history = top-up rows
filtered `origin: :auto` (badge "Auto" wherever top-ups render).
Arming `:auto` is a separate, explicitly-confirmed action from
`:reminder` (a checkbox-style consent, not a shared toggle).
Screenshots light+dark.

**Tests**: gate-off renders launch shape (no charge affordances),
gate-on renders charge card per role, arming consent flow, origin
badge.

**Done when**:
`MIX_TEST_PARTITION=s5 mix test test/flux_vale_web/live/org_live/billing_test.exs`
(and the personal-surface file) exits 0 with the new cases.

### S6 — activation (blocked on the owner's Pro upgrade)

**External precondition**: Terence has upgraded the Polar org to
Pro. Until the PA relays it, this slice is NOT scheduled.

**Steps** (mostly operator evidence, minimal code): (1) evidence
read — `GET /v1/organizations/{id}` shows
`feature_settings.off_session_charges_enabled: true`; transcript
(flag line, org id, no token) to the PA. (2) mapping evidence — a
draft order with `amount: <X>` (never finalized), GET it, record
`subtotal_amount == X`. (3) flip `AUTO_RECHARGE_CHARGE_MODE=true`
on staging with a sandbox Pro-shaped org → a staging end-to-end
proof (save method via portal, arm :auto, cross the threshold with
a compressed `RECHARGE_SWEEP_CRONEXPR`, observe the charge, the
credit, the ledger row, the balance). (4) production flip + one
real org arms it when ready. (5) this plan's Verification section
updated with the transcripts.

**Done when**: the PA holds the activation report with the two
transcripts and the staging proof capture paths.

## ADR amendment

Lands in THIS plan PR (billing-semantics change → yes, it warrants
one): [ADR-0029](../adr/00029-payments-adapter-selfmor.md)
Amendment 7 — saved methods + off-session charges join the adapter
(Polar-exclusive per the owner's decision); attempt-is-a-top-up;
consent/caps; launch-ships-the-reminder sequencing with the staged
charge lane behind the Polar Pro upgrade. Index row updated to
Amendments 1–7.

## Overall PR gate

Implementation PRs (not this one): `cd apps/platform && mix ci` —
all aliases green at 100% coverage (#86 discipline). PR titles
`feat(platform): …` per slice; `Closes #829` rides the PR that
completes the LAUNCH scope (Wave L), the staged wave references the
issue without closing it.

## Verification status

- Code citations: read on this branch (`e8b8fcc8`), files named above.
- Provider facts: HitPay docs (save-payment-method, charge-saved-card
  OpenAPI, availability-by-market PH row, sandbox guide); Polar
  2026-10 OpenAPI (`/v1/orders/`, `/v1/orders/{id}/finalize`,
  customer-sessions, customers, payment-methods) plus
  polar.sh/docs/features/orders (preview + paid-plan note, the 402/
  403/412 table, the billing-address requirement) and the fees page
  (plan table, Early Member cutoff) — fetched 2026-11-17; quotes in
  this file are from those pages.
- NOT verified (cannot be, from this repo): the production org's
  `off_session_charges_enabled` state (it is false until the Pro
  upgrade — S6's evidence read); Create Order `amount`→
  `subtotal_amount` mapping in a live call (S6); the customer-portal
  save flow's exact return UX (S6 staging proof); whether Polar's
  SANDBOX org allows draft orders pre-upgrade (if it does, S6's
  mapping evidence may run early — never blocking).
