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
  gateway's return landing (`/billing/topup/return?reference=…` —
  HitPay's own param; Polar substitutes its checkout session id into
  `checkout_id`, #377): a pending row reconciles through
  `fetch_payment` in `handle_params` — render stays side-effect-free —
  then arms a brief poll (a few ticks) so a slow webhook doesn't strand
  the buyer on the confirming state; the webhook stays the source of
  truth, the poll is presentation promptness, and both paths post the
  same idempotent credit.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Billing.Countries
  alias FluxVale.Billing.Tax
  alias FluxVale.Billing.Topup
  alias FluxVale.Pricing

  require Ash.Query
  require Logger

  @steps [:details, :amount, :payment]
  @state_format ~r/^[A-Z]{2}$/
  # The country picker's rendered cap (#364): options beyond this many
  # matches fold into a "keep typing" hint. The listbox scrolls
  # (max-h-80), so the cap is what keeps the keyboard highlight inside
  # the rows actually on screen.
  @country_rows 8
  # $1 credit unit × quantity (decided 2026-10-13, #137).
  @unit_cents 100
  # The pending confirmation's brief poll loop (#377): the webhook
  # stays the source of truth — these buys at most ~10 seconds of
  # presentation promptness on a slow delivery, then the honest
  # confirming message stands.
  @poll_interval_ms 2_000
  @poll_max_attempts 5

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
              # #285 T4: the buyer email prefills from the account's
              # PRIMARY address — `users.email` is the frozen mirror and
              # goes stale at SetPrimaryEmail. Nil primary (old-pod
              # straggler) falls back to the mirror — see
              # User.primary_email.
              email: to_string(user.primary_email || user.email),
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
          # The country combobox's open state (#364): the query the
          # buyer typed, the matches on display (capped), the keyboard
          # highlight, and whether the listbox shows at all.
          |> assign(
            country_query: "",
            country_matches: [],
            country_total: 0,
            country_active: 0,
            country_open: false
          )

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
  # The gateway's return: correlate the row, reconcile a pending row
  # once, here — render must stay side-effect free. HitPay appends
  # `reference` itself; Polar substitutes the checkout session id
  # into `checkout_id` (#377) — both are the row's
  # payment_request_id.
  def handle_params(%{"reference" => payment_request_id}, _uri, socket) do
    show_confirmation(socket, payment_request_id)
  end

  def handle_params(%{"checkout_id" => payment_request_id}, _uri, socket) do
    show_confirmation(socket, payment_request_id)
  end

  # The wizard steps don't ride the URL (a refresh restarts); only the
  # gateway's return carries params.
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # The pending confirmation's poll tick: a cheap re-read first (the
  # webhook may have completed the row since render), a gateway
  # reconcile only while the row itself still says pending.
  @impl Phoenix.LiveView
  def handle_info(:poll_topup, socket) do
    topup = socket.assigns.topup

    if refetch_state(topup) == :pending do
      poll_reconcile(socket, topup)
    else
      {:noreply, confirm_completed(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate-details", %{"details" => details} = params, socket) do
    submitted = normalize_details(details)
    details = reconcile_country(submitted, socket)

    {:noreply,
     socket
     |> assign(details: details)
     # The dropdown is the country field's own concern — typing in any
     # other field abandons the search, so its listbox folds away.
     |> close_list_on_other_field(params)
     |> assign_tax(details)}
  end

  # Enter inside the query field: the commit happens HERE, in the
  # keydown. Chromium's implicit submit clicks the default button right
  # after this keydown, so country-away + continue-details + the form's
  # next-details all follow on the channel — the listbox is closed and
  # the serialized country is stale by the time the submit lands. The
  # blank-country reconciliation in the submit handlers is what makes
  # that pairing safe; no flag can be, because the synthetic click and
  # a real Continue click are indistinguishable server-side.
  def handle_event("next-details", %{"details" => _details}, socket)
      when socket.assigns.country_open do
    {:noreply, commit_highlighted(socket)}
  end

  def handle_event("next-details", %{"details" => details}, socket) do
    submitted = normalize_details(details)
    details = reconcile_country(submitted, socket)

    if details_valid?(details) do
      {:noreply,
       socket
       |> assign(details: details, step: :amount)
       |> assign_tax(details)}
    else
      {:noreply, put_flash(socket, :error, details_error(details))}
    end
  end

  def handle_event("continue-details", _params, socket) do
    # The Continue click, ahead of its form submit: the list closes so
    # the submit advances instead of committing a highlighted option.
    {:noreply, assign(socket, country_open: false)}
  end

  def handle_event("filter-countries", %{"country_query" => query}, socket)
      when is_binary(query) do
    query = String.trim(query)
    matches = filter_countries(query)

    {:noreply,
     assign(
       socket,
       country_query: query,
       country_matches: Enum.take(matches, @country_rows),
       country_total: length(matches),
       country_active: 0,
       country_open: query != ""
     )}
  end

  # Hostile or malformed pushes fall through as silence — a
  # FunctionClauseError would kill the socket and restart the buyer's
  # wizard (the posture the pay event promises).
  def handle_event("filter-countries", _missing_or_malformed_query, socket),
    do: {:noreply, socket}

  def handle_event("select-country", %{"code" => code}, socket) do
    {:noreply, select_country(socket, code)}
  end

  def handle_event("select-country", _missing_code, socket), do: {:noreply, socket}

  # Click-away — the plain-LiveView close on outside clicks (a blur
  # binding would unmount the rows before the option's mouse-up click
  # lands). The implicit submit fires it too (Chromium clicks the
  # default button), right before the submit it precedes. Idempotent
  # while closed.
  def handle_event("country-away", _params, socket) do
    {:noreply, assign(socket, country_open: false)}
  end

  # Keyboard navigation rides the wrapper's focus. Enter is owned by
  # the implicit submit (see next-details); a closed ArrowDown reopens
  # the list; everything else is a no-op.
  def handle_event(
        "country-key",
        %{"key" => "ArrowDown"},
        %{assigns: %{country_open: true}} = socket
      ) do
    {:noreply, move_active(socket, +1)}
  end

  def handle_event(
        "country-key",
        %{"key" => "ArrowUp"},
        %{assigns: %{country_open: true}} = socket
      ) do
    {:noreply, move_active(socket, -1)}
  end

  def handle_event(
        "country-key",
        %{"key" => "Escape"},
        %{assigns: %{country_open: true}} = socket
      ) do
    {:noreply, assign(socket, country_open: false)}
  end

  def handle_event(
        "country-key",
        %{"key" => "Enter"},
        %{assigns: %{country_open: true}} = socket
      ) do
    {:noreply, commit_highlighted(socket)}
  end

  def handle_event(
        "country-key",
        %{"key" => "ArrowDown"},
        %{assigns: %{country_open: false}} = socket
      ) do
    {:noreply, reopen_country(socket)}
  end

  def handle_event("country-key", _not_a_nav_key, socket) do
    {:noreply, socket}
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
        nav_section={@nav_section}
        bare
      >
        <%!-- The gateway return wears the same band frame as the wizard
        (S9): identity + the stepper at the confirmation rung — the
        return is a wizard state, not a different page. --%>
        <div class="appgram contents">
          <section class="band">
            <div class="wrap pt-8 pb-10">
              <div class="rise">
                <.button variant="ghost" size="sm" navigate={~p"/billing"} class="-ml-2">
                  &larr; Billing
                </.button>

                <p class="eyebrow mt-4">Billing</p>
                <h1 class="page-title mt-1">Add credits</h1>
                <p class="mt-2 text-base text-ink-muted">
                  Prepaid balance for your instances.
                </p>

                <div class="mt-6">
                  <.stepper steps={topup_steps()} current={step_index(@step)} testid_prefix="topup" />
                </div>
              </div>
            </div>
          </section>

          <section class="wrap pt-10 pb-16">
            <div class="rise mx-auto max-w-2xl">
              <.confirmation
                topup={@topup}
                state={@confirmation_state}
                confirmation_balance={@confirmation_balance}
              />
            </div>
          </section>
        </div>
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
        nav_section={@nav_section}
        bare
      >
        <%!-- App-wide grammar page (S9): `bare` main + .appgram — the
        band carries the wizard's identity (S8's deploy shape: back
        link, eyebrow, page-title h1, the shared stepper in-band), and
        the steps section holds the step cards on the card language.
        The section wrapper's rise is container-level and persistent —
        the wrapper node survives every step patch, so the animation
        never replays (S8's measured pattern; a rise on a step card
        itself would). --%>
        <div class="appgram contents">
          <%!-- 1. The wizard band. --%>
          <section class="band">
            <div class="wrap pt-8 pb-10">
              <div class="rise">
                <.button variant="ghost" size="sm" navigate={~p"/billing"} class="-ml-2">
                  &larr; Billing
                </.button>

                <p class="eyebrow mt-4">Billing</p>
                <h1 class="page-title mt-1">Add credits</h1>
                <p class="mt-2 text-base text-ink-muted">
                  Prepaid balance for your instances.
                </p>

                <div class="mt-6">
                  <.stepper steps={topup_steps()} current={step_index(@step)} testid_prefix="topup" />
                </div>
              </div>
            </div>
          </section>

          <%!-- 2. The steps: one card at a time, swapped by LiveView
          patches. No rise on the step cards themselves (patch safety). --%>
          <section class="wrap pt-10 pb-16">
            <div class="rise mx-auto max-w-2xl space-y-8">
              <%= cond do %>
                <% @step == :details -> %>
                  <.details_form
                    details={@details}
                    country_query={@country_query}
                    country_matches={@country_matches}
                    country_total={@country_total}
                    country_active={@country_active}
                    country_open={@country_open}
                  />
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
          </section>
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
  attr(:country_query, :string, required: true)
  attr(:country_matches, :list, required: true)
  attr(:country_total, :integer, required: true)
  attr(:country_active, :integer, required: true)
  attr(:country_open, :boolean, required: true)

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
        <%!-- The searchable country control (#364): a plain-LiveView
            combobox — the query input's own phx-change filters the
            dataset, the listbox is LiveView-rendered (ARIA
            combobox/listbox/option), keyboard navigation rides the
            wrapper's phx-keydown, and the stored code rides the
            hidden details[country] input. --%>
        <div
          id="country-combobox"
          class="relative mb-4"
          data-testid="topup-country-combobox"
          phx-keydown="country-key"
          phx-click-away="country-away"
        >
          <label for="country-query">
            <span class="mb-1.5 block text-sm font-medium text-ink">Country</span>
            <input
              type="text"
              id="country-query"
              name="country_query"
              value={@country_query}
              placeholder="Search countries"
              autocomplete="off"
              spellcheck="false"
              required
              role="combobox"
              aria-expanded={if(@country_open, do: "true", else: "false")}
              aria-controls="country-listbox"
              aria-activedescendant={
                active_option_id(@country_open, @country_matches, @country_active)
              }
              aria-autocomplete="list"
              phx-change="filter-countries"
              class="w-full rounded-control border border-line bg-panel px-3 py-2 text-sm text-ink shadow-sm transition-[color,background-color,border-color,box-shadow] duration-(--motion-fast) placeholder:text-ink-subtle focus:outline-none focus:ring-2 focus:border-line-primary focus:ring-focus/25"
              data-testid="topup-country-input"
            />
          </label>
          <input
            type="hidden"
            name="details[country]"
            value={@details.country}
            data-testid="topup-country-value"
          />

          <%= if @country_open do %>
            <div class="absolute inset-x-0 top-full z-20 mt-1" data-testid="topup-country-listbox">
              <ul
                id="country-listbox"
                role="listbox"
                aria-labelledby="country-query"
                class="max-h-80 overflow-auto rounded-control border border-line bg-panel py-1 shadow-lg"
              >
                <%= for {country, index} <- Enum.with_index(@country_matches) do %>
                  <li
                    id={"country-option-#{index}"}
                    role="option"
                    aria-selected={if(index == @country_active, do: "true", else: "false")}
                    phx-click="select-country"
                    phx-value-code={country.code}
                    class={[
                      "flex cursor-pointer items-baseline justify-between gap-2 px-3 py-2 text-sm",
                      if(index == @country_active,
                        do: "bg-panel-raised font-medium text-ink",
                        else: "text-ink-muted"
                      )
                    ]}
                  >
                    <span>{country.name}</span>
                    <span class="font-mono text-xs text-ink-subtle">{country.code}</span>
                  </li>
                <% end %>
              </ul>
              <%= if @country_total > length(@country_matches) do %>
                <p
                  class="mt-1 rounded-control border border-line bg-panel px-3 py-2 text-xs text-ink-muted shadow-lg"
                  data-testid="topup-country-more"
                  aria-live="polite"
                >
                  …and {@country_total - length(@country_matches)} more — keep typing
                </p>
              <% end %>
              <%= if @country_total == 0 do %>
                <p
                  class="rounded-control border border-line bg-panel px-3 py-2 text-sm text-ink-muted shadow-lg"
                  data-testid="topup-country-empty"
                  aria-live="polite"
                >
                  No matching country — keep typing, or check the spelling.
                </p>
              <% end %>
            </div>
          <% end %>
        </div>
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
        <.button
          type="submit"
          size="sm"
          id="topup-details-next"
          phx-click="continue-details"
        >
          Continue
        </.button>
      </.form>
    </.card>
    """
  end

  # The combobox input's aria-activedescendant: the highlighted
  # option's id while the listbox shows matches, absent otherwise.
  defp active_option_id(true, [_match | _matches], active), do: "country-option-#{active}"
  defp active_option_id(_closed_or_empty, _matches, _active), do: nil

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
            <span class="font-mono">{signed_usd(@balance + @totals.subtotal)}</span>
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
        </.link>. By topping up you accept the <.link
          navigate={~p"/policies/terms"}
          data-testid="topup-terms"
          class="underline underline-offset-2 hover:text-ink"
        >
          Terms of Service
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
          <span class="font-mono">{signed_usd(@balance + @totals.subtotal)}</span>
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
        </.link>. By topping up you accept the <.link
          navigate={~p"/policies/terms"}
          data-testid="topup-terms"
          class="underline underline-offset-2 hover:text-ink"
        >
          Terms of Service
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
          Pay {Pricing.format_usd(@totals.total)} with {provider_label()}
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
  # The new-balance line adds the top-up to the RAW ledger sum, which
  # is negative for an overdrawn wallet — the band's celebrated
  # Depleted state is exactly who the "Add credits" CTA invites here.
  # The shared formatter is non-negative by constraint; the sign is
  # this surface's business, like every other billing display seam.
  defp signed_usd(cents) when cents < 0, do: "-" <> Pricing.format_usd(-cents)
  defp signed_usd(cents), do: Pricing.format_usd(cents)

  # #377: the pay button names the active provider (ADR-0029's
  # one-provider-via-config) — read at render, so the label rides the
  # flip with no template change. HitPay stays the fallback: an
  # unset/unknown provider renders today's text, not a blank.
  defp provider_label do
    case Application.get_env(:flux_vale, :payments_provider) do
      FluxVale.Billing.Providers.Polar -> "Polar"
      _active -> "HitPay"
    end
  end

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
  attr(:confirmation_balance, :integer, default: nil)

  defp confirmation(%{topup: nil} = assigns) do
    ~H"""
    <div class="space-y-6" data-testid="topup-confirmation">
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
      <.card class="space-y-4">
        <%= if @state == :completed do %>
          <h2
            class="flex items-center gap-2 text-base font-medium text-success"
            data-testid="topup-confirmation-completed"
          >
            <.icon name="hero-check-circle" class="size-5" /> Payment received
          </h2>
          <p class="text-sm text-ink-muted">
            <span class="font-mono">{Pricing.format_usd(@topup.amount_cents)}</span> of credit
            was added to your balance.
          </p>
          <%= if @confirmation_balance do %>
            <p class="text-sm text-ink-muted" data-testid="topup-confirmation-balance">
              Your balance is now <span class="font-mono">{Pricing.format_usd(@confirmation_balance)}</span>.
            </p>
          <% end %>
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

        <%= if @state == :expired do %>
          <h2
            class="flex items-center gap-2 text-base font-medium text-ink"
            data-testid="topup-confirmation-expired"
          >
            <.icon name="hero-clock" class="size-5" /> This payment window expired
          </h2>
          <p class="text-sm text-ink-muted">
            No credit was added. If you completed a payment, your credit will appear once the gateway confirms it.
          </p>
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

  # The confirmation landing: resolve the row (a read — an unknown or
  # garbage reference renders the not-found card, never a crash),
  # reconcile a pending row once, then arm the presentation extras.
  defp show_confirmation(socket, payment_request_id) do
    topup = fetch_topup(payment_request_id, socket.assigns.current_user)
    state = confirmation_state(topup)

    {:noreply,
     socket
     |> assign(step: :confirmation)
     |> assign(topup: topup)
     |> assign(confirmation_state: state)
     |> assign_confirmation_extras(state)}
  end

  # A completed card shows the resulting balance; a still-pending one
  # arms the poll; terminal states need neither.
  defp assign_confirmation_extras(socket, :completed) do
    confirm_completed(socket)
  end

  defp assign_confirmation_extras(socket, :pending) do
    Process.send_after(self(), :poll_topup, @poll_interval_ms)

    socket
    |> assign(confirmation_balance: nil)
    |> assign(poll_attempt: 1)
  end

  defp assign_confirmation_extras(socket, _terminal) do
    socket
    |> assign(confirmation_balance: nil)
    |> assign(poll_attempt: nil)
  end

  defp poll_reconcile(socket, topup) do
    case confirmation_state(topup) do
      :completed ->
        {:noreply, confirm_completed(socket)}

      :pending ->
        {:noreply, maybe_poll_again(socket)}

      terminal ->
        {:noreply,
         socket
         |> assign(confirmation_state: terminal)
         |> assign(poll_attempt: nil)}
    end
  end

  defp confirm_completed(socket) do
    {:ok, balance} = Billing.balance(socket.assigns.wallet, actor: socket.assigns.current_user)

    socket
    |> assign(confirmation_state: :completed)
    |> assign(confirmation_balance: balance)
    |> assign(poll_attempt: nil)
  end

  defp maybe_poll_again(socket) do
    attempt = socket.assigns.poll_attempt

    if attempt < @poll_max_attempts do
      Process.send_after(self(), :poll_topup, @poll_interval_ms)
      assign(socket, poll_attempt: attempt + 1)
    else
      socket
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
      Countries.valid?(details.country) and state_valid?(details)
  end

  # The US rate is per-state (ADR-0029 Am. 3) — a US buyer's state is
  # part of the billing evidence, so it's required to continue.
  defp state_valid?(%{country: "US"} = details),
    do: String.match?(details.state, @state_format)

  defp state_valid?(_elsewhere), do: true

  defp details_error(%{country: "US"}) do
    "Name, a valid email, a selected country, and a 2-letter US state are required."
  end

  defp details_error(_elsewhere) do
    "Name, a valid email, and a selected country are required."
  end

  # --- the country combobox (#364) ---

  # Prefix matches rank ahead of substring matches; both arms keep the
  # dataset's name-sorted order. Matching folds accents and case, and
  # runs on the code too — "PH", "Phil", and "phi" all find the
  # Philippines.
  defp filter_countries(query) do
    if query == "" do
      []
    else
      needle = fold(query)

      {prefix, rest} =
        Enum.split_with(Countries.all(), fn country ->
          String.starts_with?(fold(country.name), needle) or
            String.starts_with?(String.downcase(country.code), needle)
        end)

      substring =
        Enum.filter(rest, fn country ->
          String.contains?(fold(country.name), needle) or
            String.contains?(String.downcase(country.code), needle)
        end)

      Enum.concat(prefix, substring)
    end
  end

  # The accent-fold for matching and the dataset's sort order — the
  # letters a buyer types, not the codepoints the name carries.
  # Codepoints, not graphemes: a decomposed å is one grapheme cluster
  # ("a" + combining ring) and the mark must be dropped.
  defp fold(value) do
    value
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.codepoints()
    |> Enum.reject(fn
      <<codepoint::utf8>> when codepoint in 0x0300..0x036F -> true
      _base_character -> false
    end)
    |> Enum.join()
  end

  # The selection — the stored shape stays the 2-letter code
  # (normalize_details and open_checkout untouched); the control reads
  # "Philippines (PH)". Shared by the click, the Enter keydown, and
  # the hostile next-details commit.
  defp select_country(socket, code) do
    details = %{socket.assigns.details | country: code}

    socket
    |> assign(
      details: details,
      country_query: "#{Countries.name(code)} (#{code})",
      country_open: false
    )
    |> assign_tax(details)
  end

  # The keyboard highlight commits (nil match folds the list —
  # nothing to take).
  defp commit_highlighted(socket) do
    case Enum.at(socket.assigns.country_matches, socket.assigns.country_active) do
      nil -> assign(socket, country_open: false)
      match -> select_country(socket, match.code)
    end
  end

  defp move_active(socket, delta) do
    count = length(socket.assigns.country_matches)
    current = socket.assigns.country_active
    shifted = current + delta

    active =
      cond do
        count == 0 -> 0
        shifted < 0 -> 0
        shifted > count - 1 -> count - 1
        true -> shifted
      end

    assign(socket, country_active: active)
  end

  defp close_list_on_other_field(socket, %{"_target" => ["details", field]})
       when field != "country" do
    assign(socket, country_open: false)
  end

  defp close_list_on_other_field(socket, _same_field_or_untracked), do: socket

  # A blank submitted country is stale serialization, never intent: the
  # combobox has no clear affordance, so the only way a serialized
  # blank pairs with a server-side selection is a submit (or change)
  # that left the browser before the selection's patch landed — the
  # Enter-in-query pairing. The committed code stands; a non-blank
  # submitted country always wins (the hostile-swap case).
  defp reconcile_country(%{country: ""} = details, socket) do
    committed = socket.assigns.details.country

    if Countries.valid?(committed) do
      %{details | country: committed}
    else
      details
    end
  end

  defp reconcile_country(details, _socket), do: details

  # The list re-opens over the selected country when the buyer arrows
  # back in; before any selection it opens on the top of the dataset.
  defp reopen_country(socket) do
    code = socket.assigns.details.country

    {query, matches} =
      if code == "" do
        {"", Countries.all()}
      else
        {code, filter_countries(code)}
      end

    assign(
      socket,
      country_query: query,
      country_matches: Enum.take(matches, @country_rows),
      country_total: length(matches),
      country_active: 0,
      country_open: true
    )
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
