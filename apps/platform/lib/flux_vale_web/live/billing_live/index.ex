defmodule FluxValeWeb.BillingLive.Index do
  @moduledoc """
  The billing surface (#123): the org wallet's balance and paginated
  ledger history. Balance is the live ledger sum (`Billing.balance/2`);
  history is keyset-paginated newest-first, appended into the stream by
  "Load more" — cursors survive rows landing between pages, offset
  windows wouldn't.

  "Add credits" opens the top-up wizard (#137). No live updates:
  balance reads at mount; the wizard's confirmation refreshes on its
  own navigation.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Pricing

  @page_size 25

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case Accounts.personal_org_for_user(user.id, actor: user) do
      {:ok, org} ->
        # ensure_wallet is the system seam (idempotent); every read
        # below runs against the actor through the wallet policies.
        {:ok, wallet} = Billing.ensure_wallet(org)
        {:ok, balance} = Billing.balance(wallet, actor: user)

        page = ledger_page(wallet.id, user)

        socket =
          socket
          |> stream(:entries, page.results)
          |> assign(wallet: wallet, balance: balance, page: page)

        {:ok, socket}

      :none ->
        # Unreachable for action-created users (JIT org provisioning);
        # a seeded/legacy row without an org lands here.
        {:ok,
         socket
         |> put_flash(:error, "No organization found for this account.")
         |> push_navigate(to: ~p"/apps")}
    end
  end

  @impl Phoenix.LiveView
  # Single-clause def with a literal head pattern: OTP cover's entry
  # counter for this shape never fires (the body lines carry the hits) —
  # same artifact class as the defguard exclusion in DebitWallet.
  # coveralls-ignore-next-line
  def handle_event("load-more", _params, socket) do
    case Ash.page(socket.assigns.page, :next) do
      {:ok, page} ->
        # Exhaustion is uniform here: an empty last page appends nothing
        # and retires the button (more? false).
        {:noreply,
         socket
         |> stream(:entries, page.results, at: -1)
         |> assign(:page, page)}

      {:error, reason} ->
        # defensive: DB read failure between render and click — not
        # simulatable under the sandbox; the next click retries.
        # coveralls-ignore-start
        require Logger

        Logger.error("Ledger page load failed: #{inspect(reason)}")
        {:noreply, socket}
        # coveralls-ignore-stop
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-6">
        <h1 class="text-3xl font-bold tracking-tight">Billing</h1>

        <div class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Balance</h2>
            <p class="text-4xl font-bold tracking-tight" data-testid="wallet-balance">
              {format_balance(@balance)}
            </p>
            <div class="flex flex-wrap items-center gap-3">
              <.link navigate={~p"/billing/topup"} class="btn btn-primary btn-sm" id="add-credits">
                Add credits
              </.link>
              <span class="text-xs opacity-60">
                Credits can be used for any app, never expire, and are non-refundable.
              </span>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">History</h2>
            <div id="entries" phx-update="stream" class="divide-y divide-base-300">
              <div id="entries-empty" class="py-3 text-sm opacity-60 hidden only:block">
                No activity yet.
              </div>
              <div
                :for={{dom_id, entry} <- @streams.entries}
                id={dom_id}
                data-testid="ledger-row"
                class="flex items-center justify-between gap-3 py-3"
              >
                <span class="text-sm opacity-70">
                  {Calendar.strftime(entry.created_at, "%b %d, %Y %H:%M UTC")}
                </span>
                <span class="text-sm capitalize">{entry.reason}</span>
                <span class={["font-mono text-sm", amount_color(entry)]}>
                  {format_amount(entry.amount)}
                </span>
              </div>
            </div>
            <button
              :if={@page.more?}
              id="load-more"
              phx-click="load-more"
              class="btn btn-ghost btn-sm"
            >
              Load more
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp ledger_page(wallet_id, user) do
    LedgerEntry
    |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet_id}, actor: user)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.read!(page: [limit: @page_size])
  end

  # Prices (Pricing.format_usd/1) are non-negative by constraint; the
  # ledger carries signed cents — negative balances and debit rows get
  # their own sign handling here, at the billing display seam.
  defp format_balance(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  defp format_balance(cents) do
    Pricing.format_usd(cents)
  end

  defp format_amount(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  defp format_amount(cents) do
    "+" <> Pricing.format_usd(cents)
  end

  defp amount_color(%LedgerEntry{type: :credit}) do
    "text-success"
  end

  defp amount_color(%LedgerEntry{type: :debit}) do
    "text-error"
  end
end
