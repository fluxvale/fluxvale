defmodule FluxValeWeb.OrganizationLive.Billing do
  @moduledoc """
  The org billing view (#276): the `/billing` surface — balance and
  paginated ledger — scoped to the URL's org instead of the actor's
  personal one. Slug-keyed mount like the catalog; unknown slugs and
  policy denials read as "not here" — one arm, one answer, so a
  non-member's probe is indistinguishable from a typo (no enumeration).

  No "Add credits" CTA on purpose: the top-up wizard resolves the
  actor's personal org in its mount, so a CTA here would be a lie for
  any future non-personal org — org-context top-up is a future lane.
  The page links to `/billing` instead.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxValeWeb.BillingComponents

  # Mirrors BillingLive.Index — same read, same window; the pages differ
  # only in which org they resolved.
  @page_size 25

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        # ensure_wallet is the system seam (idempotent); every read
        # below runs against the actor through the wallet policies —
        # the personal page's posture, the org resolved from the URL.
        {:ok, wallet} = Billing.ensure_wallet(org)
        {:ok, balance} = Billing.balance(wallet, actor: user)

        page = ledger_page(wallet.id, user)

        socket =
          socket
          |> stream(:entries, page.results)
          |> assign(
            org: org,
            wallet: wallet,
            balance: balance,
            page: page,
            history_empty?: page.results == []
          )

        {:ok, socket}

      _error ->
        # The member-scoped read policy filters an unknown slug and a
        # non-member's target to the same nothing.
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
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
      current_org={@org}
    >
      <div class="space-y-6">
        <.header>
          Billing
          <:subtitle>Prepaid credits fund {@org.name}'s instances.</:subtitle>
        </.header>

        <.card class="space-y-4">
          <BillingComponents.balance_header balance={@balance} />
          <p class="text-xs text-ink-subtle">
            <%!-- No "Add credits" here: the top-up wizard resolves the
                actor's personal org in its mount, so a wizard CTA on an
                org page would top up the wrong wallet the moment this
                route serves a non-personal org. Org-context top-up is a
                future lane; until it lands, top-ups start from the
                personal billing page. --%>
            Top up from <.link
              navigate={~p"/billing"}
              data-testid="topup-link"
              class="underline underline-offset-2 hover:text-ink"
            >
              Billing
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
