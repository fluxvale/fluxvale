defmodule FluxValeWeb.BillingComponents do
  @moduledoc """
  Shared billing render pieces (#276): the wallet facts, the paginated
  ledger history, and the auto-recharge card (#829 L3). Extracted from
  `BillingLive.Index` when the org billing view
  (`/organizations/:slug/billing`) needed the same shape over a
  URL-resolved org. The top-up CTA and its notice stay page-owned —
  the wizard is personal-org-pinned — so only the genuinely identical
  markup lives here.
  """

  use FluxValeWeb, :html

  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Month
  alias FluxVale.Billing.Tax
  alias FluxVale.Pricing

  @micro_per_cent 10_000

  @doc """
  The wallet facts as the grammar's in-band posture (S9, the S4/S6
  shape): Balance and Runway as eyebrow-labeled values. The projection
  is `Billing.compute_runway/1` — the same struct the dashboard's band
  shows, so the two surfaces can never disagree about the wallet.

  The pair stacks below 760px and sits end-anchored side-by-side above:
  the runway value's longest shape ("No active burn") is wider than the
  S6 pair's fixtures, so the S6 at-375 side-by-side fit doesn't hold
  here — the stack is the measured composition, not a wrap.
  """
  attr(:facts, :any,
    required: true,
    doc: "the Billing.compute_runway/1 projection: balance, runway, burn"
  )

  @spec wallet_facts(map()) :: Phoenix.LiveView.Rendered.t()
  def wallet_facts(assigns) do
    ~H"""
    <div class="flex flex-col gap-y-6 min-[760px]:flex-row min-[760px]:items-start min-[760px]:gap-x-14">
      <div data-testid="wallet-balance">
        <p class="eyebrow">Balance</p>
        <p class="mt-1.5 whitespace-nowrap text-3xl font-bold tracking-tight text-ink min-[760px]:text-4xl min-[900px]:text-5xl">
          {format_balance(@facts.balance_cents)}
        </p>
      </div>

      <div data-testid="wallet-runway">
        <p class="eyebrow">Runway</p>
        <p class="mt-1.5 whitespace-nowrap text-3xl font-bold tracking-tight text-ink min-[760px]:text-4xl min-[900px]:text-5xl">
          {format_runway(@facts)}
        </p>
        <p class="mt-1 text-xs text-ink-subtle">{burn_hint(@facts)}</p>
      </div>
    </div>
    """
  end

  @doc """
  The paginated ledger history rows: the empty state, the newest-first
  stream rows, and the "Load more" button — retired at exhaustion via
  `page.more?`. Appends ride the rendering LiveView's "load-more"
  handler; the component owns only the markup. The section heading is
  the pages' (S9: the S4/S6 section shape — heading outside the card).
  Timestamps and amounts ride the mono register — ledger rows are
  technical content (S8's confirm-step register).
  """
  attr(:entries, :list, required: true, doc: "the stream: {dom_id, entry} tuples")
  attr(:page, :any, required: true, doc: "the current Ash keyset page (more? gates the button)")

  attr(:history_empty?, :boolean, required: true, doc: "no rows at all — the empty state")

  @spec ledger_history(map()) :: Phoenix.LiveView.Rendered.t()
  def ledger_history(assigns) do
    ~H"""
    <.card>
      <%!-- Empty state lives OUTSIDE the stream container: streams
          can't count, and an in-stream hidden placeholder makes
          divide/border selectors render a phantom row divider
          (vision QA round 2). --%>
      <p :if={@history_empty?} class="text-sm text-ink-subtle" data-testid="ledger-empty">
        No activity yet.
      </p>
      <div id="entries" phx-update="stream">
        <div
          :for={{dom_id, entry} <- @entries}
          id={dom_id}
          data-testid="ledger-row"
          class="flex items-center justify-between gap-4 border-t border-line py-3 first:border-t-0"
        >
          <%!-- The mono register steps down below 480px: the fixed-format
              timestamp (22 mono chars) plus the widest fixture amount
              overshoots the 320 viewport by ~1px at text-sm — measured,
              the S6 lesson (the guard is the row's own arithmetic, not
              a wrap). --%>
          <span class="font-mono text-xs whitespace-nowrap text-ink-muted min-[480px]:text-sm">
            {Calendar.strftime(entry.created_at, "%b %d, %Y %H:%M UTC")}
          </span>
          <span class="min-w-0 flex-1 truncate text-sm text-ink capitalize">
            {reason_label(entry.reason)}
          </span>
          <span class={[
            "font-mono text-xs whitespace-nowrap min-[480px]:text-sm",
            amount_color(entry)
          ]}>
            {format_amount(entry.amount)}
          </span>
        </div>
      </div>
      <div class="mt-4">
        <.button :if={@page.more?} id="load-more" variant="ghost" size="sm" phx-click="load-more">
          Load more
        </.button>
      </div>
    </.card>
    """
  end

  @doc """
  The auto-recharge card (#829): L3's launch shape — the reminder
  lane's state and, for owners, its form — plus S5's staged CHARGE
  presentation, rendered ONLY when `charge_mode?` (the platform gate,
  `Billing.auto_recharge_charge_mode?/0`) is true. Gate-off the card
  renders byte-for-byte the launch shape: no charge affordances, no
  `:auto` option, no add-method, no evidence fields — the parity pin
  test rides the launch testids and nothing more.

  The gate-on presentation: the saved-method block (status + the
  owner's "Add payment method" button — enabled only when the setting
  carries a billing country, the provider taxes against it); the last
  3 `:auto` top-ups (the org's money history, member-visible like the
  ledger); the owner form extended with the charge dials and buyer
  evidence; and the `:auto` arming confirm — a second, explicit step
  whose copy names the gross math ("max charged/day = cap × (amount +
  VAT at your rate)"), never a side effect of saving settings. The
  disable reason renders an honest line naming why the lane stopped.

  The form gate is UX only: `owner?` rides the write policy's own
  ownership check (`ActorIsOrganizationOwner`, one ownership notion),
  but the resource's `:set` policy is what actually forbids — a
  member's crafted submit dies at the domain seam as an error flash,
  never a crash. The gate is enforced HERE, not just at mount: the
  form renders only for an owner with a form, so a crafted
  validate event (which re-assigns the form) cannot resurrect it on a
  member's view. Money rides `Pricing.format_usd_whole_or_exact/1` —
  the L2 mail's exact-cents rule, one formatter for both surfaces.
  A non-round stored value prefills EMPTY (an unedited save would
  silently floor 549¢ to 500¢), with an inline hint naming the stored
  exact value; whole-round values prefill as today.

  The `:auto` option mirrors the AutoArmGate (method attached, gate
  on) — the domain validation is the real gate; the select is UX.

  Shared by the org billing page and the personal one (same band +
  ledger shape, same card); the events it raises
  (`save-auto-recharge` / `validate-auto-recharge` /
  `add-payment-method` / `confirm-arm-auto` / `cancel-arm-auto`) are
  the rendering LiveView's — the surfaces wire them identically, each
  owning its private copies (the operation-boundary stance: follow the
  pattern, not the function).
  """
  attr(:setting, :any,
    required: true,
    doc: "the org's AutoRechargeSetting row (Billing.ensure_auto_recharge_setting/1's)"
  )

  attr(:owner?, :boolean,
    required: true,
    doc: "owner-role actors get the form; members read the state"
  )

  attr(:form, :any, required: true, doc: "the owner's prefilled form (nil for members)")

  attr(:charge_mode?, :boolean,
    required: true,
    doc:
      "the platform gate (Billing.auto_recharge_charge_mode?/0) — everything chargey renders only gate-on"
  )

  attr(:arm_confirm?, :boolean,
    default: false,
    doc:
      "gate-on: the arming confirm step is showing (set by the save handler, cleared by confirm/cancel)"
  )

  attr(:auto_topups, :list,
    default: [],
    doc: "gate-on: the last 3 :auto top-ups (the card's attempt history)"
  )

  @spec auto_recharge_card(map()) :: Phoenix.LiveView.Rendered.t()
  def auto_recharge_card(assigns) do
    setting = assigns.setting

    assigns =
      assigns
      |> assign(:min_topup_dollars, FluxVale.Billing.min_topup_dollars())
      |> assign(
        threshold_exact?: rem(setting.threshold_cents, 100) != 0,
        amount_exact?: rem(setting.amount_cents, 100) != 0,
        # The Add-method button's enabler (decision C): the provider
        # taxes charges against the billing address, so the session
        # request needs the setting's country.
        evidence_saved?: is_binary(setting.billing_country) and setting.billing_country != "",
        # The :auto option mirrors the AutoArmGate (the validation is
        # the real gate — a crafted :auto is refused at the domain).
        auto_option?: assigns.charge_mode? and setting.payment_method_status == :attached,
        disabled_copy: disabled_copy(setting),
        # Display-only VAT (the rate resolves FRESH at charge time,
        # #260 — never a copied rate): the confirm copy's figure reads
        # the current rate table over the stored evidence. Computed
        # ONLY when the confirm step shows — the quote is a TaxRate
        # table read, never a per-render cost (gate-off rows and the
        # closed-confirm common case do no such work).
        arm_gross_cents:
          if(assigns.charge_mode? and assigns.arm_confirm?, do: arm_gross_cents(setting)),
        method_copy: method_copy(setting)
      )

    ~H"""
    <.card id="auto-recharge-card" class="space-y-4" data-testid="auto-recharge-card">
      <div>
        <h2 class="text-base font-medium text-ink">Auto-recharge</h2>
        <p class="mt-1 text-sm text-ink-muted" data-testid="auto-recharge-state">
          <%= cond do %>
            <% @charge_mode? and @setting.mode == :auto -> %>
              Auto charging armed: we'll charge {Pricing.format_usd_whole_or_exact(
                @setting.amount_cents
              )} when the balance drops below {Pricing.format_usd_whole_or_exact(
                @setting.threshold_cents
              )} — at most {@setting.daily_charge_cap} {plural(@setting.daily_charge_cap, "charge")} a
              day.
            <% @setting.mode == :reminder -> %>
              Reminders on: we'll email your org a one-click top-up link when the balance drops
              below {Pricing.format_usd_whole_or_exact(@setting.threshold_cents)} — at most once
              a day.
            <% true -> %>
              Reminders are off.
          <% end %>
        </p>
        <p
          :if={@setting.mode == :reminder}
          class="mt-1 text-sm text-ink-muted"
          data-testid="auto-recharge-amount"
        >
          Each link pre-fills a {Pricing.format_usd_whole_or_exact(@setting.amount_cents)} top-up.
        </p>
        <p
          :if={not @owner?}
          class="mt-1 text-xs text-ink-subtle"
          data-testid="auto-recharge-member-hint"
        >
          Only the organization owner can change this.
        </p>
        <%!-- S4's disable arm (declines / no-method) is why an armed
            lane can be off — the honest line names it. Hidden once
            re-armed (:auto): a stale reason must not contradict the
            armed state above. --%>
        <p
          :if={@charge_mode? and not is_nil(@disabled_copy) and @setting.mode != :auto}
          class="mt-1 text-sm text-danger"
          data-testid="auto-recharge-disabled"
        >
          {@disabled_copy}
        </p>
      </div>

      <%!-- The saved-method block (gate-on): status + provider-customer
          presence, and the owner's portal click. The button's enabler is
          the setting's billing country (the request requires it); the
          disable is honest with a hint at the evidence fields below. --%>
      <div
        :if={@charge_mode?}
        class="border-t border-line pt-4"
        data-testid="auto-recharge-method"
      >
        <p class="eyebrow">Payment method</p>
        <p class="mt-1 text-sm text-ink-muted" data-testid="auto-recharge-method-status">
          {@method_copy}
        </p>
        <div :if={@owner?} class="mt-3">
          <.button
            phx-click="add-payment-method"
            id="add-payment-method"
            size="sm"
            variant="secondary"
            disabled={not @evidence_saved?}
            data-testid="add-payment-method"
          >
            Add payment method
          </.button>
          <p
            :if={not @evidence_saved?}
            class="mt-1.5 text-xs text-ink-subtle"
            data-testid="auto-recharge-method-hint"
          >
            Save a billing country in the charge settings below first — charges are taxed
            against it.
          </p>
        </div>
      </div>

      <%!-- Recent auto activity (gate-on): the last 3 :auto rows — the
          org's money history, member-visible like the ledger. --%>
      <div
        :if={@charge_mode?}
        class="border-t border-line pt-4"
        data-testid="auto-recharge-activity"
      >
        <p class="eyebrow">Recent auto top-ups</p>
        <p
          :if={@auto_topups == []}
          class="mt-1 text-sm text-ink-muted"
          data-testid="auto-recharge-activity-empty"
        >
          No auto top-ups yet.
        </p>
        <div class="mt-2">
          <div
            :for={topup <- @auto_topups}
            data-testid="auto-recharge-activity-row"
            class="flex items-center justify-between gap-4 py-1.5"
          >
            <span class="font-mono text-xs whitespace-nowrap text-ink-muted">
              {Calendar.strftime(topup.created_at, "%b %d, %Y")}
            </span>
            <span class="min-w-0 flex-1 truncate text-sm text-ink">
              {status_label(topup.status)}
            </span>
            <span class="font-mono text-xs whitespace-nowrap text-ink">
              {Pricing.format_usd_whole_or_exact(topup.amount_cents)}
            </span>
          </div>
        </div>
      </div>

      <%!-- The owner gate rides the CARD, not just the mount: a crafted
          validate event re-assigns the form, and this :if is what keeps
          a member's view formless under it (the domain seam stays the
          authority for the write itself). --%>
      <.form
        :if={@owner? and @form}
        for={@form}
        id="auto-recharge-form"
        phx-change="validate-auto-recharge"
        phx-submit="save-auto-recharge"
        class="space-y-4 border-t border-line pt-4"
        data-testid="auto-recharge-form"
      >
        <%!-- Gate-off the form offers reminders only (the launch shape).
            Gate-on the select gains :auto — ONLY with a method attached;
            the AutoArmGate validation is the real gate. --%>
        <.input
          field={@form[:mode]}
          type="select"
          label="Reminders"
          options={
            [{"Off", "off"}, {"On", "reminder"}] ++
              if(@auto_option?, do: [{"Auto", "auto"}], else: [])
          }
          data-testid="auto-recharge-mode"
        />
        <div class="grid gap-4 min-[560px]:grid-cols-2">
          <div>
            <%!-- No `required` on the dollar inputs: a mode-off save is
                mode-only (the never-floor rule leaves them empty on a
                non-round row), and blocking that submit would force the
                owner to re-enter stored values just to switch reminders
                off. The whole-dollar validation is the server's. --%>
            <.input
              field={@form[:threshold_dollars]}
              type="number"
              label="Remind below (USD)"
              min="1"
              step="1"
              data-testid="auto-recharge-threshold"
            />
            <p
              :if={@threshold_exact? and @form[:threshold_dollars].value in [nil, ""]}
              class="mt-1 text-xs text-ink-subtle"
              data-testid="auto-recharge-threshold-hint"
            >
              Stored: {Pricing.format_usd_whole_or_exact(@setting.threshold_cents)} — enter a whole-dollar
              amount to update.
            </p>
          </div>
          <div>
            <.input
              field={@form[:amount_dollars]}
              type="number"
              label="Top-up amount (USD)"
              min={@min_topup_dollars}
              step="1"
              data-testid="auto-recharge-amount-input"
            />
            <p
              :if={@amount_exact? and @form[:amount_dollars].value in [nil, ""]}
              class="mt-1 text-xs text-ink-subtle"
              data-testid="auto-recharge-amount-hint"
            >
              Stored: {Pricing.format_usd_whole_or_exact(@setting.amount_cents)} — enter a
              whole-dollar amount to update.
            </p>
          </div>
        </div>

        <%!-- The staged charge settings (S5, gate-on): the dials
            (decision D2) and the buyer evidence (decision C). The
            resource's constraints are the authority — this form is UX. --%>
        <div
          :if={@charge_mode?}
          class="space-y-4 border-t border-line pt-4"
          data-testid="auto-recharge-charge-fields"
        >
          <div class="grid gap-4 min-[560px]:grid-cols-2">
            <.input
              field={@form[:daily_charge_cap]}
              type="number"
              label="Max charges per day"
              min="1"
              max="6"
              step="1"
              data-testid="auto-recharge-cap"
            />
            <.input
              field={@form[:failure_strikes]}
              type="number"
              label="Disable after this many declines"
              min="2"
              max="5"
              step="1"
              data-testid="auto-recharge-strikes"
            />
          </div>
          <div class="grid gap-4 min-[560px]:grid-cols-2">
            <.input
              field={@form[:billing_country]}
              type="text"
              label="Billing country (ISO code)"
              data-testid="auto-recharge-country"
            />
            <.input
              field={@form[:billing_state]}
              type="text"
              label="Billing state / province"
              data-testid="auto-recharge-state-input"
            />
          </div>
          <div class="grid gap-4 min-[560px]:grid-cols-2">
            <.input
              field={@form[:customer_type]}
              type="select"
              label="Customer type"
              options={[{"Consumer", "consumer"}, {"Business", "business"}]}
              data-testid="auto-recharge-customer-type"
            />
            <.input
              field={@form[:vat_number]}
              type="text"
              label="VAT number (business buyers)"
              data-testid="auto-recharge-vat"
            />
          </div>
        </div>

        <div class="flex justify-end">
          <.button type="submit" size="sm" id="auto-recharge-save" data-testid="auto-recharge-save">
            Save
          </.button>
        </div>
      </.form>

      <%!-- Arming :auto is its own CONFIRMED action (decision G) —
          never a side effect of saving settings. The confirm copy names
          the gross math; the figure is display-only (the rate resolves
          fresh at charge time). --%>
      <div
        :if={@charge_mode? and @owner? and @arm_confirm?}
        class="space-y-3 border-t border-line pt-4"
        data-testid="auto-recharge-arm-confirm"
      >
        <p class="text-sm font-medium text-ink">Confirm auto charging</p>
        <p class="text-sm text-ink-muted">
          We'll charge your saved card automatically when the balance drops below the threshold.
        </p>
        <p class="text-sm text-ink-muted" data-testid="auto-recharge-arm-math">
          Max charged/day = {@setting.daily_charge_cap} ×
          ({Pricing.format_usd_whole_or_exact(@setting.amount_cents)} + VAT at your rate) — up to {Pricing.format_usd_whole_or_exact(
            @arm_gross_cents
          )} per day.
        </p>
        <div class="flex gap-2">
          <.button
            phx-click="confirm-arm-auto"
            phx-value-amount={@setting.amount_cents}
            phx-value-threshold={@setting.threshold_cents}
            phx-value-cap={@setting.daily_charge_cap}
            phx-value-strikes={@setting.failure_strikes}
            id="arm-auto-confirm"
            size="sm"
            data-testid="auto-recharge-arm-confirm-button"
          >
            Confirm auto charging
          </.button>
          <.button
            phx-click="cancel-arm-auto"
            id="arm-auto-cancel"
            size="sm"
            variant="secondary"
            data-testid="auto-recharge-arm-cancel-button"
          >
            Cancel
          </.button>
        </div>
      </div>
    </.card>
    """
  end

  # The saved-method status line (gate-on): the status plus the
  # provider-customer presence — a linked profile with no method yet
  # reads differently from no profile at all.
  defp method_copy(%{payment_method_status: :attached}),
    do: "Saved — auto charging will use it."

  defp method_copy(%{payment_method_status: :none, provider_customer_id: id})
       when is_binary(id) and id != "",
       do: "None saved yet — your billing profile is linked. Add a card to enable auto charging."

  defp method_copy(_nothing_linked),
    do: "None saved yet. Add a card to enable auto charging."

  # Why an armed lane stopped (S4's disable arm) — nil reads no line.
  # The map keeps one executable line for coveralls; each reason is the
  # copy itself.
  defp disabled_copy(%{disabled_reason: nil}), do: nil

  defp disabled_copy(%{disabled_reason: reason}) do
    copy = %{
      manual: "Auto charging was turned off.",
      declines:
        "Auto charging was stopped after repeated declined charges — check your card, then re-arm.",
      no_method:
        "Auto charging was stopped because no saved payment method was found — add one, then re-arm."
    }

    Map.fetch!(copy, reason)
  end

  # The confirm step's gross figure: cap × (amount + VAT), VAT quoted
  # over the stored evidence at the CURRENT rate table — display only,
  # the charge itself resolves the rate fresh (#260). An unpriced
  # market quotes 0 (ResolveTaxRate's stance).
  defp arm_gross_cents(setting) do
    evidence = %{
      billing_country: setting.billing_country,
      billing_state: setting.billing_state,
      customer_type: setting.customer_type,
      vat_number: setting.vat_number
    }

    quote = Tax.quote(evidence, setting.amount_cents)
    setting.daily_charge_cap * (setting.amount_cents + quote.tax_cents)
  end

  defp status_label(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> String.capitalize()
  end

  @doc """
  The signed-cents BALANCE string: "-$3.00" / "$12.34". Prices
  (Pricing.format_usd/1) are non-negative by constraint; the balance is
  the live ledger sum and can go negative, so the sign is this billing
  display seam's job. Public since the admin wallets surface (#501):
  one formatter per shape means the operator table, the wallet detail,
  and the member billing page can never disagree about what a balance
  reads as.
  """
  @spec format_balance(integer()) :: String.t()
  def format_balance(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  def format_balance(cents) when is_integer(cents) do
    Pricing.format_usd(cents)
  end

  # The runway copy is owned at the billing display seam. One rule
  # ordering decides the phrase: an overdrawn balance reads Depleted
  # before the hours get a vote (a spent wallet is out of runway —
  # "under an hour" would read as nearly-there), a wallet with nothing
  # burning reads No active burn, then the rounded hours and days over
  # the average Gregorian month (Billing.Month, the same constant the
  # projection and the settles use). Public since the #702 console's
  # runway widget renders the same phrase.
  @doc """
  The runway phrase for a projection: "Depleted" for an overdrawn
  balance, "No active burn" for `:infinity`, "under an hour", then
  rounded hours and days over the average Gregorian month
  (`Billing.Month`, the constant the projection and the settles use).
  """
  @spec format_runway(%{balance_cents: integer(), runway_hours: float() | :infinity}) ::
          String.t()
  def format_runway(%{balance_cents: cents}) when cents < 0, do: "Depleted"

  def format_runway(%{runway_hours: :infinity}), do: "No active burn"

  def format_runway(%{runway_hours: hours}) when hours < 1, do: "under an hour"

  def format_runway(%{runway_hours: hours}) when hours < 48,
    do: "≈ #{round(hours)} #{plural(round(hours), "hour")}"

  def format_runway(%{runway_hours: hours}) do
    days = hours / 24

    if days < 60 do
      "≈ #{round(days)} #{plural(round(days), "day")}"
    else
      months = days * 24 * 3600 / Month.seconds()
      "≈ #{round(months)} #{plural(round(months), "month")}"
    end
  end

  defp burn_hint(%{burn_micro_cents_per_hour: 0}), do: "Nothing burning right now."

  defp burn_hint(%{burn_micro_cents_per_hour: burn_micro}) do
    # ComputeRunway truncates the rate into µ¢/h (hourly_micro's div);
    # reconstructing with div would truncate again — every rate then
    # displays a cent low ($1.00/mo read "$0.99/mo", $10.00/mo
    # "$9.99/mo"). Half-up rounding recovers the nearest cent of the
    # already-truncated rate (CodeRabbit #351). Cent-boundary budget:
    # the truncation loss is per SOURCE (< 1 µ¢/h ≈ 0.073¢ each), so a
    # burn summed from ≥ 7 sources can push past this 0.5¢ window and
    # still round a cent low — exactness per-source, approximate for
    # many-source totals.
    half_divisor = div(@micro_per_cent * 3600, 2)

    monthly_cents =
      div(burn_micro * Month.seconds() + half_divisor, @micro_per_cent * 3600)

    "at #{Pricing.format_usd(monthly_cents)}/mo current burn"
  end

  defp plural(1, unit), do: unit
  defp plural(_n, unit), do: "#{unit}s"

  @doc """
  The ledger row's signed amount: "+$12.34" / "-$3.00" — a posting is a
  delta, and the sign carries the direction the row's type names. Same
  display seam as `format_balance/1`; the admin ledger prints the same
  dollars the org billing page does.
  """
  @spec format_amount(integer()) :: String.t()
  def format_amount(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  def format_amount(cents) when is_integer(cents) do
    "+" <> Pricing.format_usd(cents)
  end

  defp amount_color(%LedgerEntry{type: :credit}) do
    "text-success"
  end

  defp amount_color(%LedgerEntry{type: :debit}) do
    "text-danger"
  end

  # Display copy at the billing seam: raw reason atoms read as bare
  # words — "welcome" deserves its product name (vision QA round 2).
  defp reason_label(:welcome), do: "Welcome credit"

  defp reason_label(reason) when is_atom(reason) do
    word = to_string(reason)
    String.capitalize(word)
  end
end
