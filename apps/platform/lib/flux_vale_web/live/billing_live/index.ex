defmodule FluxValeWeb.BillingLive.Index do
  @moduledoc """
  The billing surface (#123): the org wallet's facts and paginated
  ledger history. The band's Balance/Runway facts ride the
  `Billing.compute_runway/1` projection (the dashboard's source — one
  wallet story for both surfaces); history is keyset-paginated
  newest-first, appended into the stream by "Load more" — cursors
  survive rows landing between pages, offset windows wouldn't.

  "Add credits" opens the top-up wizard (#137). No live updates:
  facts read at mount; the wizard's confirmation refreshes on its
  own navigation. The band facts and the ledger history render
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
        # ensure_wallet is the system seam (idempotent); the facts ride
        # the runway projection (balance included — the dashboard's
        # source), the ledger read runs against the actor through the
        # wallet policies.
        {:ok, wallet} = Billing.ensure_wallet(org)
        {:ok, runway} = Billing.compute_runway(wallet)

        page = ledger_page(wallet.id, user)

        socket =
          socket
          |> stream(:entries, page.results)
          |> assign(
            wallet: wallet,
            runway: runway,
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
      bare
    >
      <%!-- App-wide grammar page (S9): `bare` main + .appgram — the page
      owns ALL of main's rhythm. The sunken band is the wallet: title +
      CTA on the S6 band shape, the facts as eyebrow-labeled values
      (the S4/S6 in-band posture, NOT floating stat cards), and the
      top-up notice as the band's small print. No straddle (the one
      straddle stays the instance show's, per S4's verdict). --%>
      <div class="appgram contents">
        <%!-- 1. The wallet band. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
                <div class="min-w-0">
                  <p class="eyebrow">Wallet</p>
                  <h1 class="page-title mt-1.5">Billing</h1>
                  <p class="mt-2 text-base text-ink-muted">
                    Prepaid credits fund your instances.
                  </p>
                </div>

                <div class="flex shrink-0 gap-2">
                  <.button navigate={~p"/billing/topup"} variant="secondary" id="add-credits">
                    Add credits
                  </.button>
                </div>
              </div>

              <div class="mt-9">
                <BillingComponents.wallet_facts facts={@runway} />
              </div>

              <p class="mt-6 text-xs text-ink-subtle" data-testid="topup-notice">
                Credits can be used for any app, never expire, and are non-refundable — <.link
                  navigate={~p"/policies/refund"}
                  data-testid="topup-refund-policy"
                  class="underline underline-offset-2 hover:text-ink"
                >
                  refund policy
                </.link>.
              </p>
            </div>
          </div>
        </section>

        <%!-- 2. The ledger — the S4/S6 section shape: heading outside the
        card, container-level rise (the stream patches rewrite rows in
        place; a rise on patched nodes would replay the reveal — node
        identity is what the rise rides). --%>
        <section aria-labelledby="billing-history-title" class="wrap pt-10 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <h2 id="billing-history-title" class="text-lg font-semibold tracking-tight text-ink">
              History
            </h2>

            <BillingComponents.ledger_history
              entries={@streams.entries}
              page={@page}
              history_empty?={@history_empty?}
            />
          </div>
        </section>
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
