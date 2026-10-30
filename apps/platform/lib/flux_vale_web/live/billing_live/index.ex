defmodule FluxValeWeb.BillingLive.Index do
  @moduledoc """
  The billing surface (#123): the org wallet's balance and paginated
  ledger history. Balance is the live ledger sum (`Billing.balance/2`);
  history is keyset-paginated newest-first, appended into the stream by
  "Load more" — cursors survive rows landing between pages, offset
  windows wouldn't.

  "Add credits" opens the top-up wizard (#137). No live updates:
  balance reads at mount; the wizard's confirmation refreshes on its
  own navigation. The balance header and the ledger history render
  through BillingComponents — shared with the org billing view (#276).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxValeWeb.BillingComponents

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
          |> assign(
            wallet: wallet,
            balance: balance,
            page: page,
            history_empty?: page.results == []
          )

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
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
    >
      <div class="space-y-6">
        <.header>
          Billing
          <:subtitle>Prepaid credits fund your instances.</:subtitle>
        </.header>

        <.card class="space-y-4">
          <div class="flex flex-wrap items-end justify-between gap-4">
            <BillingComponents.balance_header balance={@balance} />

            <.button navigate={~p"/billing/topup"} size="sm" id="add-credits">
              Add credits
            </.button>
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
        </.card>

        <BillingComponents.ledger_history
          entries={@streams.entries}
          page={@page}
          history_empty?={@history_empty?}
        />
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
end
