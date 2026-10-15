defmodule FluxValeWeb.BillingLive.Topup do
  @moduledoc """
  The top-up wizard (#137, PikaPods-shaped): a $1 credit unit bought in
  quantity — Billing Details → Amount → Payment → Confirmation. Credits
  can be used for any app, never expire, and are non-refundable; the
  Amount step states it alongside the live VAT line (0% until the tax
  layer, #138 — "final taxes are calculated at checkout") and the
  new-balance preview.

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
  alias FluxVale.Billing.Topup
  alias FluxVale.Pricing

  require Ash.Query
  require Logger

  @steps [:details, :amount, :payment]
  @country_format ~r/^[A-Z]{2}$/
  # $1 credit unit × quantity (decided 2026-10-13, #137).
  @unit_cents 100

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case Accounts.personal_org_for_user(user.id, actor: user) do
      {:ok, org} ->
        {:ok, wallet} = Billing.ensure_wallet(org)
        {:ok, balance} = Billing.balance(wallet, actor: user)

        socket =
          socket
          |> assign(org: org, wallet: wallet, balance: balance)
          |> assign(step: :details)
          |> assign(details: %{name: "", email: to_string(user.email), country: ""})
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
    {:noreply, assign(socket, details: normalize_details(details))}
  end

  def handle_event("next-details", %{"details" => details}, socket) do
    details = normalize_details(details)

    if details_valid?(details) do
      {:noreply, assign(socket, details: details, step: :amount)}
    else
      {:noreply,
       put_flash(socket, :error, "Name, a valid email, and a 2-letter country code are required.")}
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
    params = %{
      amount_cents: assigns.amount_dollars * @unit_cents,
      redirect_url: redirect_url(),
      buyer_email: assigns.details.email,
      buyer_name: assigns.details.name,
      billing_country: assigns.details.country
    }

    case Billing.start_topup(assigns.org, params) do
      {:ok, _topup, checkout_url} ->
        {:noreply, redirect(socket, external: checkout_url)}

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

  @impl Phoenix.LiveView
  def render(assigns) do
    if assigns.step == :confirmation do
      ~H"""
      <Layouts.app flash={@flash} current_user={@current_user}>
        <.confirmation topup={@topup} state={@confirmation_state} />
      </Layouts.app>
      """
    else
      ~H"""
      <Layouts.app flash={@flash} current_user={@current_user}>
        <div class="space-y-6">
          <h1 class="text-3xl font-bold tracking-tight">Add credits</h1>

          <.stepper step={@step} />

          <%= cond do %>
            <% @step == :details -> %>
              <.details_form details={@details} />
            <% @step == :amount -> %>
              <.amount_step amount_dollars={@amount_dollars} balance={@balance} />
            <% @step == :payment -> %>
              <.payment_step details={@details} amount_dollars={@amount_dollars} balance={@balance} />
          <% end %>
        </div>
      </Layouts.app>
      """
    end
  end

  attr :step, :atom, required: true

  defp stepper(assigns) do
    steps = [
      {:details, "Billing details"},
      {:amount, "Amount"},
      {:payment, "Payment"},
      {:confirmation, "Confirmation"}
    ]

    current_index = Enum.find_index(steps, fn {key, _label} -> key == assigns.step end)
    last_index = length(steps) - 1

    assigns =
      assigns
      |> assign(steps: steps)
      |> assign(current_index: current_index)
      |> assign(last_index: last_index)

    ~H"""
    <ol class="flex items-center gap-2 text-sm" data-testid="topup-stepper">
      <%= for {{key, label}, index} <- Enum.with_index(@steps) do %>
        <li
          class={[
            "flex items-center gap-2",
            index < @current_index && "text-success",
            index == @current_index && "font-semibold",
            index > @current_index && "opacity-50"
          ]}
          data-testid={"topup-step-#{key}"}
        >
          <span class={[
            "flex size-6 items-center justify-center rounded-full border text-xs",
            index < @current_index && "border-success bg-success/10",
            index == @current_index && "border-primary bg-primary/10",
            index > @current_index && "border-base-300"
          ]}>
            {index + 1}
          </span>
          {label}
        </li>
        <%= if index < @last_index do %>
          <span class="h-px w-4 bg-base-300" aria-hidden="true"></span>
        <% end %>
      <% end %>
    </ol>
    """
  end

  attr :details, :map, required: true

  defp details_form(assigns) do
    form =
      to_form(
        %{
          "name" => assigns.details.name,
          "email" => assigns.details.email,
          "country" => assigns.details.country
        },
        as: :details
      )

    assigns = assign(assigns, form: form)

    ~H"""
    <div class="card bg-base-200">
      <div class="card-body gap-4">
        <h2 class="card-title text-base">Billing details</h2>
        <p class="text-sm opacity-70">
          Used for your receipt. Final taxes are calculated at checkout.
        </p>

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
          <button type="submit" class="btn btn-primary btn-sm" id="topup-details-next">
            Continue
          </button>
        </.form>
      </div>
    </div>
    """
  end

  attr :amount_dollars, :integer, default: nil
  attr :balance, :integer, required: true

  defp amount_step(assigns) do
    dollars =
      if is_integer(assigns.amount_dollars),
        do: Integer.to_string(assigns.amount_dollars),
        else: ""

    form = to_form(%{"dollars" => dollars}, as: :amount)
    assigns = assign(assigns, form: form)

    ~H"""
    <div class="card bg-base-200">
      <div class="card-body gap-4">
        <h2 class="card-title text-base">How much credit?</h2>

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
          <button type="submit" class="btn btn-primary btn-sm" id="topup-amount-next">
            Continue
          </button>
        </.form>

        <%= if is_integer(@amount_dollars) and @amount_dollars >= 1 do %>
          <div class="rounded-lg bg-base-300/50 p-4 space-y-2 text-sm" data-testid="topup-summary">
            <p class="flex justify-between">
              <span class="opacity-70">{@amount_dollars} × $1.00 credit</span>
              <span class="font-mono">{Pricing.format_usd(@amount_dollars * 100)}</span>
            </p>
            <p class="flex justify-between" data-testid="topup-taxes">
              <span class="opacity-70">Taxes (0%)</span>
              <span class="font-mono">{Pricing.format_usd(0)}</span>
            </p>
            <p
              class="flex justify-between font-semibold border-t border-base-300 pt-2"
              data-testid="topup-total"
            >
              <span>Total</span>
              <span class="font-mono">{Pricing.format_usd(@amount_dollars * 100)}</span>
            </p>
            <p class="text-xs opacity-60">Final taxes are calculated at checkout.</p>
            <p
              class="flex justify-between text-xs opacity-70 border-t border-base-300 pt-2"
              data-testid="topup-new-balance"
            >
              <span>New balance after top-up</span>
              <span class="font-mono">{Pricing.format_usd(@balance + @amount_dollars * 100)}</span>
            </p>
          </div>
        <% end %>

        <p class="text-xs opacity-60" data-testid="topup-notice">
          Credits can be used for any app, never expire, and are non-refundable.
        </p>

        <button phx-click="back" class="btn btn-ghost btn-sm" id="topup-amount-back">Back</button>
      </div>
    </div>
    """
  end

  attr :details, :map, required: true
  attr :amount_dollars, :integer, required: true
  attr :balance, :integer, required: true

  defp payment_step(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body gap-4">
        <h2 class="card-title text-base">Review and pay</h2>

        <div class="rounded-lg bg-base-300/50 p-4 space-y-2 text-sm" data-testid="topup-summary">
          <p class="flex justify-between">
            <span class="opacity-70">Credit</span>
            <span class="font-mono">{@amount_dollars} × $1.00 = {Pricing.format_usd(
              @amount_dollars * 100
            )}</span>
          </p>
          <p class="flex justify-between" data-testid="topup-taxes">
            <span class="opacity-70">Taxes (0%)</span>
            <span class="font-mono">{Pricing.format_usd(0)}</span>
          </p>
          <p
            class="flex justify-between font-semibold border-t border-base-300 pt-2"
            data-testid="topup-total"
          >
            <span>Total</span>
            <span class="font-mono">{Pricing.format_usd(@amount_dollars * 100)}</span>
          </p>
          <p
            class="flex justify-between text-xs opacity-70 border-t border-base-300 pt-2"
            data-testid="topup-new-balance"
          >
            <span>New balance after top-up</span>
            <span class="font-mono">{Pricing.format_usd(@balance + @amount_dollars * 100)}</span>
          </p>
          <p class="flex justify-between text-xs opacity-70">
            <span>Billed to</span>
            <span>{@details.name} · {@details.email} · {@details.country}</span>
          </p>
        </div>

        <p class="text-xs opacity-60" data-testid="topup-notice">
          Credits can be used for any app, never expire, and are non-refundable.
        </p>

        <div class="flex items-center gap-3">
          <button phx-click="pay" class="btn btn-primary btn-sm" id="topup-pay">
            Pay {Pricing.format_usd(@amount_dollars * 100)} with HitPay
          </button>
          <button phx-click="back" class="btn btn-ghost btn-sm" id="topup-payment-back">
            Back
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :topup, :map, default: nil
  attr :state, :atom, required: true

  defp confirmation(%{topup: nil} = assigns) do
    ~H"""
    <div class="space-y-6" data-testid="topup-confirmation">
      <h1 class="text-3xl font-bold tracking-tight">Add credits</h1>
      <div class="card bg-base-200">
        <div class="card-body gap-4">
          <h2 class="card-title text-base">We couldn't find that top-up</h2>
          <p class="text-sm opacity-70">
            The payment reference wasn't recognized for your account.
          </p>
          <.link navigate={~p"/billing"} class="btn btn-primary btn-sm">
            Back to billing
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp confirmation(assigns) do
    ~H"""
    <div class="space-y-6" data-testid="topup-confirmation">
      <h1 class="text-3xl font-bold tracking-tight">Add credits</h1>
      <div class="card bg-base-200">
        <div class="card-body gap-4">
          <%= if @state == :completed do %>
            <h2 class="card-title text-base text-success" data-testid="topup-confirmation-completed">
              Payment received
            </h2>
            <p class="text-sm opacity-70">
              {Pricing.format_usd(@topup.amount_cents)} of credit was added to your balance.
            </p>
          <% end %>

          <%= if @state == :failed do %>
            <h2 class="card-title text-base text-error" data-testid="topup-confirmation-failed">
              The payment didn't go through
            </h2>
            <p class="text-sm opacity-70">No credit was added and nothing was charged.</p>
          <% end %>

          <%= if @state == :pending do %>
            <h2 class="card-title text-base" data-testid="topup-confirmation-pending">
              Finalizing your payment
            </h2>
            <p class="text-sm opacity-70">
              The gateway is still confirming the payment. Your credit lands
              the moment it does — nothing more to do here.
            </p>
          <% end %>

          <.link navigate={~p"/billing"} class="btn btn-primary btn-sm" id="topup-back-to-billing">
            Back to billing
          </.link>
        </div>
      </div>
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
    country =
      (details["country"] || "")
      |> String.trim()
      |> String.upcase()

    %{
      name: String.trim(details["name"] || ""),
      email: String.trim(details["email"] || ""),
      country: country
    }
  end

  defp details_valid?(details) do
    details.name != "" and valid_email?(details.email) and
      String.match?(details.country, @country_format)
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

  # The gateway appends its reference/status query args to this; the
  # endpoint's configured host is the externally reachable one.
  defp redirect_url do
    FluxValeWeb.Endpoint.url() <> "/billing/topup/return"
  end
end
