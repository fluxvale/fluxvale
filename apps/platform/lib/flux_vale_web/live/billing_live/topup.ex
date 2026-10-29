defmodule FluxValeWeb.BillingLive.Topup do
  @moduledoc """
  The top-up wizard (#137, PikaPods-shaped): a $1 credit unit bought in
  quantity — Billing Details → Amount → Payment → Confirmation. Credits
  can be used for any app, never expire, and are non-refundable.

  Credits are a single-purpose voucher: VAT is collected at top-up,
  added on top of the credit value (#138, ADR-0029 Am. 3 gate 2). The
  Details step captures the buyer evidence (country, US state, customer
  type, VAT number) and the IP country rides the session
  (`FluxValeWeb.Plugs.CaptureIpCountry`); the rate resolves from the
  validated details — reverse charge zeroes it — and recomputes on
  every details edit. That resolved assign is the single source the
  steps display AND the charge spends (#260): no second lookup at pay
  time, so the VAT line, the total, and the charge can never price
  different rates. A rate-table change mid-session fails the checkout
  closed (StartTopup's authoritative guard) and re-displays the current
  figures for a fresh consent — a charge never carries a total the
  buyer didn't see. "Final taxes at checkout" is gone: the wizard
  prices the charge.

  Steps 1–3 are LiveView state (a refresh restarts the wizard — the
  buyer hasn't paid anything until the gateway redirect). Step 4 is the
  gateway's return landing (`/billing/topup/return?reference=…`): a
  pending row reconciles through `fetch_payment` in `handle_params` —
  render stays side-effect-free — and the webhook stays the source of
  truth; both paths post the same idempotent credit.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Billing.Tax
  alias FluxVale.Billing.Topup
  alias FluxVale.Pricing

  require Ash.Query
  require Logger

  @steps [:details, :amount, :payment]
  @country_format ~r/^[A-Z]{2}$/
  @state_format ~r/^[A-Z]{2}$/
  # $1 credit unit × quantity (decided 2026-10-13, #137).
  @unit_cents 100

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    case Accounts.personal_org_for_user(user.id, actor: user) do
      {:ok, org} ->
        {:ok, wallet} = Billing.ensure_wallet(org)
        {:ok, balance} = Billing.balance(wallet, actor: user)

        socket =
          socket
          |> assign(org: org, wallet: wallet, balance: balance)
          |> assign(step: :details)
          |> assign(
            details: %{
              name: "",
              email: to_string(user.email),
              country: "",
              state: "",
              customer_type: :consumer,
              vat_number: ""
            }
          )
          # The second location signal rides the session (the edge geo
          # header, CaptureIpCountry). Absent is fine — recorded, never
          # blocking; the billing address decides the rate.
          |> assign(ip_country: session["ip_country"])
          |> assign(tax_rate_bp: 0, reverse_charge?: false)
          |> assign(amount_dollars: nil)

        {:ok, socket}

      :none ->
        # Same posture as the billing page: unreachable for
        # action-created users; a legacy row without an org lands here.
        {:ok,
         socket
         |> put_flash(:error, "No organization found for this account.")
         |> push_navigate(to: ~p"/apps")}
    end
  end

  @impl Phoenix.LiveView
  # The gateway's return: reconcile a pending row once, here — render
  # must stay side-effect free.
  def handle_params(%{"reference" => reference}, _uri, socket) do
    topup = fetch_topup(reference, socket.assigns.current_user)
    state = confirmation_state(topup)

    {:noreply,
     socket
     |> assign(step: :confirmation)
     |> assign(topup: topup)
     |> assign(confirmation_state: state)}
  end

  # The wizard steps don't ride the URL (a refresh restarts); only the
  # gateway's return carries params.
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate-details", %{"details" => details}, socket) do
    details = normalize_details(details)

    {:noreply,
     socket
     |> assign(details: details)
     |> assign_tax(details)}
  end

  def handle_event("next-details", %{"details" => details}, socket) do
    details = normalize_details(details)

    if details_valid?(details) do
      {:noreply,
       socket
       |> assign(details: details, step: :amount)
       |> assign_tax(details)}
    else
      {:noreply, put_flash(socket, :error, details_error(details))}
    end
  end

  def handle_event("back", _params, socket) do
    index = Enum.find_index(@steps, &(&1 == socket.assigns.step))

    if index in [nil, 0] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, step: Enum.at(@steps, index - 1))}
    end
  end

  def handle_event("validate-amount", %{"amount" => %{"dollars" => dollars}}, socket) do
    {:noreply, assign(socket, amount_dollars: parse_dollars(dollars))}
  end

  def handle_event("next-amount", %{"amount" => %{"dollars" => dollars}}, socket) do
    amount = parse_dollars(dollars)

    if is_integer(amount) and amount >= 1 do
      {:noreply, assign(socket, amount_dollars: amount, step: :payment)}
    else
      {:noreply, put_flash(socket, :error, "Enter a whole-dollar amount of at least $1.")}
    end
  end

  def handle_event("pay", _params, socket) do
    assigns = socket.assigns

    # The wizard's order is client-controlled — the event that opens a
    # checkout re-validates everything it spends, so a hostile client
    # that skips steps gets silence, never a blank-receipt charge.
    if payable?(assigns) do
      # The displayed rate is the charged rate (#260): the assign the
      # steps render is the single source the charge spends — StartTopup
      # re-checks it against the rate table and fails closed if the
      # table moved under the session.
      open_checkout(socket, assigns)
    else
      {:noreply, socket}
    end
  end

  defp payable?(assigns) do
    assigns.step == :payment and is_integer(assigns.amount_dollars) and
      assigns.amount_dollars >= 1 and details_valid?(assigns.details)
  end

  defp open_checkout(socket, assigns) do
    details = assigns.details
    amount_cents = assigns.amount_dollars * @unit_cents

    params = %{
      amount_cents: amount_cents,
      redirect_url: redirect_url(),
      buyer_email: details.email,
      buyer_name: details.name,
      billing_country: details.country,
      billing_state: present(details.state),
      customer_type: details.customer_type,
      vat_number: present(details.vat_number),
      ip_country: assigns.ip_country,
      tax_rate_bp: assigns.tax_rate_bp,
      tax_cents: Tax.tax_cents(amount_cents, assigns.tax_rate_bp)
    }

    case Billing.start_topup(assigns.org, params) do
      {:ok, _topup, checkout_url} ->
        {:noreply, redirect(socket, external: checkout_url)}

      {:error, :tax_rate_mismatch} ->
        # The rate table moved under the session — nothing was charged.
        # Re-resolve so the steps display the current figures and the
        # buyer consents again; the retried pay charges exactly what
        # the refreshed display shows.
        {:noreply,
         socket
         |> assign_tax(assigns.details)
         |> put_flash(
           :error,
           "The VAT rate changed — nothing was charged. The total below is updated; review and pay again."
         )}

      {:error, :missing_config} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Payments aren't configured on this environment yet. Nothing was charged."
         )}

      {:error, reason} ->
        Logger.error("Top-up checkout failed: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           "The checkout couldn't be opened. Nothing was charged — try again."
         )}
    end
  end

  # The rate every step displays and the charge spends (#260) — one
  # resolution the whole session consumes, from VALIDATED details
  # only: reverse charge zeroes it (the customer self-accounts);
  # otherwise the billing country's table row (state-specific for the
  # US). StartTopup validates the charge against its own table
  # resolution; a mid-session change answers :tax_rate_mismatch and
  # the caller re-runs this for the fresh display.
  defp assign_tax(socket, details) do
    if details_valid?(details) do
      assign(socket,
        tax_rate_bp: applied_rate(details),
        reverse_charge?: Tax.reverse_charge?(details.customer_type, details.vat_number)
      )
    else
      # Partial/invalid edits never price a rate — the 0% placeholder
      # stands until the details validate.
      assign(socket, tax_rate_bp: 0, reverse_charge?: false)
    end
  end

  defp applied_rate(details) do
    reverse_charge? = Tax.reverse_charge?(details.customer_type, details.vat_number)

    if reverse_charge? do
      0
    else
      Pricing.resolve_tax_rate(details.country, present(details.state), DateTime.utc_now())
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    if assigns.step == :confirmation do
      ~H"""
      <Layouts.app
        flash={@flash}
        current_user={@current_user}
        actor_orgs={@actor_orgs}
        personal_org_id={@personal_org_id}
        username={@username}
      >
        <.confirmation topup={@topup} state={@confirmation_state} />
      </Layouts.app>
      """
    else
      ~H"""
      <Layouts.app
        flash={@flash}
        current_user={@current_user}
        actor_orgs={@actor_orgs}
        personal_org_id={@personal_org_id}
        username={@username}
      >
        <div class="space-y-6">
          <.header>
            Add credits
            <:subtitle>Prepaid balance for your instances.</:subtitle>
          </.header>

          <.stepper steps={topup_steps()} current={step_index(@step)} testid_prefix="topup" />

          <%= cond do %>
            <% @step == :details -> %>
              <.details_form details={@details} />
            <% @step == :amount -> %>
              <.amount_step
                amount_dollars={@amount_dollars}
                balance={@balance}
                tax_rate_bp={@tax_rate_bp}
                reverse_charge?={@reverse_charge?}
              />
            <% @step == :payment -> %>
              <.payment_step
                details={@details}
                amount_dollars={@amount_dollars}
                balance={@balance}
                tax_rate_bp={@tax_rate_bp}
                reverse_charge?={@reverse_charge?}
              />
          <% end %>
        </div>
      </Layouts.app>
      """
    end
  end

  # The wizard's ordered steps — shared by the stepper and step-index
  # math (public <.stepper> component, #178 wave 2). Ids are the step
  # ATOMS (the render's @step) — string ids would never match and
  # find_index's nil makes every index "less than" it (Elixir's total
  # term order: numbers < atoms), painting all steps done.
  defp topup_steps do
    [
      {:details, "Billing details"},
      {:amount, "Amount"},
      {:payment, "Payment"},
      {:confirmation, "Confirmation"}
    ]
  end

  defp step_index(step) do
    Enum.find_index(topup_steps(), fn {key, _label} -> key == step end)
  end

  attr(:details, :map, required: true)

  defp details_form(assigns) do
    form =
      to_form(
        %{
          "name" => assigns.details.name,
          "email" => assigns.details.email,
          "country" => assigns.details.country,
          "state" => assigns.details.state,
          "customer_type" => Atom.to_string(assigns.details.customer_type),
          "vat_number" => assigns.details.vat_number
        },
        as: :details
      )

    assigns = assign(assigns, form: form)

    ~H"""
    <.card class="space-y-4">
      <div>
        <h2 class="text-base font-medium text-ink">Billing details</h2>
        <p class="mt-1 text-sm text-ink-muted">
          Used for your receipt and to apply the right VAT.
        </p>
      </div>

      <.form
        for={@form}
        id="topup-details-form"
        phx-change="validate-details"
        phx-submit="next-details"
        class="space-y-4"
      >
        <.input field={@form[:name]} label="Name" placeholder="Jane Doe" required />
        <.input
          field={@form[:email]}
          label="Email"
          type="email"
          placeholder="jane@example.com"
          required
        />
        <.input field={@form[:country]} label="Country code" placeholder="DE" required />
        <%= if @details.country == "US" do %>
          <.input field={@form[:state]} label="State" placeholder="CA" required />
        <% end %>
        <.input
          field={@form[:customer_type]}
          label="Customer type"
          type="select"
          options={[{"Consumer", "consumer"}, {"Business", "business"}]}
        />
        <%= if @details.customer_type == :business do %>
          <.input
            field={@form[:vat_number]}
            label="VAT number"
            placeholder="DE123456789"
          />
        <% end %>
        <.button type="submit" size="sm" id="topup-details-next">
          Continue
        </.button>
      </.form>
    </.card>
    """
  end

  attr(:amount_dollars, :integer, default: nil)
  attr(:balance, :integer, required: true)
  attr(:tax_rate_bp, :integer, required: true)
  attr(:reverse_charge?, :boolean, required: true)

  defp amount_step(assigns) do
    dollars =
      if is_integer(assigns.amount_dollars),
        do: Integer.to_string(assigns.amount_dollars),
        else: ""

    assigns =
      assigns
      |> assign(form: to_form(%{"dollars" => dollars}, as: :amount))
      |> assign(totals: totals(assigns))

    ~H"""
    <.card class="space-y-4">
      <h2 class="text-base font-medium text-ink">How much credit?</h2>

      <.form
        for={@form}
        id="topup-amount-form"
        phx-change="validate-amount"
        phx-submit="next-amount"
        class="space-y-4"
      >
        <.input
          field={@form[:dollars]}
          label="Amount (whole US dollars)"
          type="number"
          min="1"
          step="1"
          placeholder="10"
          required
        />
        <div class="flex items-center gap-3">
          <.button type="submit" size="sm" id="topup-amount-next">
            Continue
          </.button>
          <.button variant="ghost" size="sm" type="button" phx-click="back" id="topup-amount-back">
            Back
          </.button>
        </div>
      </.form>

      <%= if is_integer(@amount_dollars) and @amount_dollars >= 1 do %>
        <%!-- Receipt panels on the card language (#277 T6): the backups
            sub-panel idiom — panel radius, raised fill, line-strong
            border (in dark --line IS --panel-raised, so a border or
            hairline on this fill vanishes unless it rides the strong
            step; the in-panel row hairlines below ride it too). --%>
        <div
          class="space-y-2 rounded-panel border border-line-strong bg-panel-raised p-4 text-sm"
          data-testid="topup-summary"
        >
          <p class="flex justify-between">
            <span class="text-ink-muted">{@amount_dollars} × $1.00 credit</span>
            <span class="font-mono text-ink">{Pricing.format_usd(@totals.subtotal)}</span>
          </p>
          <p class="flex justify-between" data-testid="topup-taxes">
            <span class="text-ink-muted">{taxes_label(@reverse_charge?, @tax_rate_bp)}</span>
            <span class="font-mono text-ink">{Pricing.format_usd(@totals.tax)}</span>
          </p>
          <p
            class="flex justify-between border-t border-line-strong pt-2 font-semibold text-ink"
            data-testid="topup-total"
          >
            <span>Total</span>
            <span class="font-mono">{Pricing.format_usd(@totals.total)}</span>
          </p>
          <p
            class="flex justify-between border-t border-line-strong pt-2 text-xs text-ink-muted"
            data-testid="topup-new-balance"
          >
            <span>New balance after top-up</span>
            <span class="font-mono">{Pricing.format_usd(@balance + @totals.subtotal)}</span>
          </p>
        </div>
      <% end %>

      <p class="text-xs text-ink-subtle" data-testid="topup-notice">
        Credits can be used for any app, never expire, and are non-refundable — <.link
          navigate={~p"/policies/refund"}
          data-testid="topup-refund-policy"
          class="underline underline-offset-2 hover:text-ink"
        >
          refund policy
        </.link>.
      </p>
    </.card>
    """
  end

  attr(:details, :map, required: true)
  attr(:amount_dollars, :integer, required: true)
  attr(:balance, :integer, required: true)
  attr(:tax_rate_bp, :integer, required: true)
  attr(:reverse_charge?, :boolean, required: true)

  defp payment_step(assigns) do
    assigns = assign(assigns, totals: totals(assigns))

    ~H"""
    <.card class="space-y-4">
      <h2 class="text-base font-medium text-ink">Review and pay</h2>

      <%!-- Same receipt panel idiom as the Amount step (#277 T6). --%>
      <div
        class="space-y-2 rounded-panel border border-line-strong bg-panel-raised p-4 text-sm"
        data-testid="topup-summary"
      >
        <p class="flex justify-between">
          <span class="text-ink-muted">Credit</span>
          <span class="font-mono text-ink">{@amount_dollars} × $1.00 = {Pricing.format_usd(
            @totals.subtotal
          )}</span>
        </p>
        <p class="flex justify-between" data-testid="topup-taxes">
          <span class="text-ink-muted">{taxes_label(@reverse_charge?, @tax_rate_bp)}</span>
          <span class="font-mono text-ink">{Pricing.format_usd(@totals.tax)}</span>
        </p>
        <p
          class="flex justify-between border-t border-line-strong pt-2 font-semibold text-ink"
          data-testid="topup-total"
        >
          <span>Total</span>
          <span class="font-mono">{Pricing.format_usd(@totals.total)}</span>
        </p>
        <p
          class="flex justify-between border-t border-line-strong pt-2 text-xs text-ink-muted"
          data-testid="topup-new-balance"
        >
          <span>New balance after top-up</span>
          <span class="font-mono">{Pricing.format_usd(@balance + @totals.subtotal)}</span>
        </p>
        <%!-- billed_to is buyer-typed and can run long and unbroken
            (name · email · VAT) — the guards let it wrap inside its
            cell instead of blowing the receipt out. --%>
        <p class="flex justify-between gap-3 text-xs text-ink-muted">
          <span class="shrink-0">Billed to</span>
          <span
            class="min-w-0 text-right [overflow-wrap:anywhere]"
            data-testid="topup-billed-to"
          >{billed_to(@details)}</span>
        </p>
      </div>

      <p class="text-xs text-ink-subtle" data-testid="topup-notice">
        Credits can be used for any app, never expire, and are non-refundable — <.link
          navigate={~p"/policies/refund"}
          data-testid="topup-refund-policy"
          class="underline underline-offset-2 hover:text-ink"
        >
          refund policy
        </.link>.
      </p>

      <p class="text-xs text-ink-subtle" data-testid="topup-correction">
        Billing details or VAT look wrong? Let us know if this is not correct.
      </p>

      <div class="flex items-center gap-3">
        <.button
          size="sm"
          phx-click="pay"
          phx-disable-with="Opening checkout…"
          id="topup-pay"
        >
          Pay {Pricing.format_usd(@totals.total)} with HitPay
        </.button>
        <.button variant="ghost" size="sm" phx-click="back" id="topup-payment-back">
          Back
        </.button>
      </div>
    </.card>
    """
  end

  # Net credit, VAT, and the gross the gateway will charge — one math
  # source for the Amount and Payment steps.
  defp totals(%{amount_dollars: dollars, tax_rate_bp: rate_bp})
       when is_integer(dollars) and dollars >= 1 do
    subtotal = dollars * @unit_cents
    tax = Tax.tax_cents(subtotal, rate_bp)
    %{subtotal: subtotal, tax: tax, total: subtotal + tax}
  end

  defp totals(_unset), do: %{subtotal: 0, tax: 0, total: 0}

  defp taxes_label(true, _rate_bp), do: "VAT (reverse charge, 0%)"
  defp taxes_label(false, rate_bp), do: "VAT (#{Tax.percent_label(rate_bp)}%)"

  defp billed_to(details) do
    [details.name, details.email, details.country]
    |> append_present(details.state)
    |> append_present(present(details.vat_number) && "VAT " <> details.vat_number)
    |> Enum.join(" · ")
  end

  defp append_present(parts, value) when is_binary(value) and value != "",
    do: parts ++ [value]

  defp append_present(parts, _absent), do: parts

  attr(:topup, :map, default: nil)
  attr(:state, :atom, required: true)

  defp confirmation(%{topup: nil} = assigns) do
    ~H"""
    <div class="space-y-6" data-testid="topup-confirmation">
      <.header>
        Add credits
      </.header>
      <.card class="space-y-4">
        <h2 class="text-base font-medium text-ink">We couldn't find that top-up</h2>
        <p class="text-sm text-ink-muted">
          The payment reference wasn't recognized for your account.
        </p>
        <div>
          <.button navigate={~p"/billing"} size="sm">
            Back to billing
          </.button>
        </div>
      </.card>
    </div>
    """
  end

  defp confirmation(assigns) do
    ~H"""
    <div class="space-y-6" data-testid="topup-confirmation">
      <.header>
        Add credits
      </.header>
      <.card class="space-y-4">
        <%= if @state == :completed do %>
          <h2
            class="flex items-center gap-2 text-base font-medium text-success"
            data-testid="topup-confirmation-completed"
          >
            <.icon name="hero-check-circle" class="size-5" /> Payment received
          </h2>
          <p class="text-sm text-ink-muted">
            {Pricing.format_usd(@topup.amount_cents)} of credit was added to your balance.
          </p>
        <% end %>

        <%= if @state == :failed do %>
          <h2
            class="flex items-center gap-2 text-base font-medium text-danger"
            data-testid="topup-confirmation-failed"
          >
            <.icon name="hero-x-circle" class="size-5" /> The payment didn't go through
          </h2>
          <p class="text-sm text-ink-muted">No credit was added and nothing was charged.</p>
        <% end %>

        <%= if @state == :pending do %>
          <h2
            class="flex items-center gap-2 text-base font-medium text-ink"
            data-testid="topup-confirmation-pending"
          >
            <.icon name="hero-arrow-path" class="size-5 motion-safe:animate-spin" />
            Finalizing your payment
          </h2>
          <p class="text-sm text-ink-muted">
            The gateway is still confirming the payment. Your credit lands
            the moment it does — nothing more to do here.
          </p>
        <% end %>

        <div>
          <.button navigate={~p"/billing"} size="sm" id="topup-back-to-billing">
            Back to billing
          </.button>
        </div>
      </.card>
    </div>
    """
  end

  # The row's display state: terminal rows speak for themselves; a
  # pending row reconciles (fetch through the active provider). The
  # disconnected render runs mount+handle_params twice and refreshes
  # re-run it — downstream idempotency makes that safe; errors and
  # non-terminal gateway states leave the finalizing message.
  defp confirmation_state(nil), do: :unknown

  defp confirmation_state(%Topup{status: status}) when status != :pending, do: status

  defp confirmation_state(%Topup{status: :pending} = topup) do
    case Billing.reconcile_topup(topup.payment_request_id) do
      {:ok, %Topup{} = fresh} -> fresh.status
      {:ok, :already_completed} -> :completed
      # A racing delivery transitioned the row after our read — re-read
      # for the truth rather than guessing which way it went.
      {:ok, :already_terminal} -> refetch_state(topup)
      {:ok, :pending} -> :pending
      {:error, _reason} -> :pending
    end
  end

  defp refetch_state(topup) do
    case Topup.get_by_id(topup.id, authorize?: false) do
      {:ok, fresh} -> fresh.status
      # Topup has no destroy action — a read failure here is a DB
      # outage mid-render, not simulatable under the sandbox; the
      # finalizing message is the safe fallback.
      # coveralls-ignore-next-line
      {:error, _gone} -> :pending
    end
  end

  defp fetch_topup(payment_request_id, user) do
    result =
      Topup
      |> Ash.Query.for_read(:read, %{}, actor: user)
      |> Ash.Query.filter(payment_request_id == ^payment_request_id)
      |> Ash.Query.limit(1)
      |> Ash.read()

    case result do
      {:ok, [topup | _rest]} -> topup
      _none -> nil
    end
  end

  defp normalize_details(details) do
    country = trim_upcase(details["country"])
    state = trim_upcase(details["state"])
    vat_number = trim_upcase(details["vat_number"])

    customer_type =
      case details["customer_type"] do
        "business" -> :business
        _anything_else -> :consumer
      end

    %{
      name: String.trim(details["name"] || ""),
      email: String.trim(details["email"] || ""),
      country: country,
      state: state,
      customer_type: customer_type,
      vat_number: vat_number
    }
  end

  defp trim_upcase(value) do
    (value || "")
    |> String.trim()
    |> String.upcase()
  end

  defp details_valid?(details) do
    details.name != "" and valid_email?(details.email) and
      String.match?(details.country, @country_format) and state_valid?(details)
  end

  # The US rate is per-state (ADR-0029 Am. 3) — a US buyer's state is
  # part of the billing evidence, so it's required to continue.
  defp state_valid?(%{country: "US"} = details),
    do: String.match?(details.state, @state_format)

  defp state_valid?(_elsewhere), do: true

  defp details_error(%{country: "US"}) do
    "Name, a valid email, a 2-letter country code, and a 2-letter US state are required."
  end

  defp details_error(_elsewhere) do
    "Name, a valid email, and a 2-letter country code are required."
  end

  defp valid_email?(email) do
    String.match?(email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/)
  end

  defp parse_dollars(raw) do
    case Integer.parse(raw || "") do
      {dollars, ""} when dollars >= 1 -> dollars
      _invalid -> nil
    end
  end

  # Empty optional fields ride the row as NULL, never "".
  defp present(""), do: nil
  defp present(value), do: value

  # The gateway appends its reference/status query args to this; the
  # endpoint's configured host is the externally reachable one.
  defp redirect_url do
    FluxValeWeb.Endpoint.url() <> "/billing/topup/return"
  end
end
