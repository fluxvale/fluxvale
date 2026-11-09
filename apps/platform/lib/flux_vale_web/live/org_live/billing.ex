defmodule FluxValeWeb.OrganizationLive.Billing do
  @moduledoc """
  The org billing view (#276): the `/billing` surface — balance and
  paginated ledger — scoped to the URL's org instead of the actor's
  personal one. Slug-keyed mount like the catalog; unknown slugs and
  policy denials read as "not here" — one arm, one answer, so a
  non-member's probe is indistinguishable from a typo (no enumeration).

  The band's Top up wallet CTA opens the org-scoped top-up wizard
  (#408): a top-up credits the URL org's wallet. The personal org has
  no view here at all (S5): its URL redirects to `/billing` — one
  wallet, one surface.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxValeWeb.BillingComponents
  alias FluxValeWeb.PersonalOrg

  # Mirrors BillingLive.Index — same read, same window; the pages differ
  # only in which org they resolved.
  @page_size 25

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        if PersonalOrg.personal?(socket, org) do
          # S5: no separate balance view for the personal org — its
          # wallet IS /billing. Flash-free redirect (nothing failed).
          {:ok, push_navigate(socket, to: ~p"/billing")}
        else
          mount_org_billing(socket, org, user)
        end

      _error ->
        # The member-scoped read policy filters an unknown slug and a
        # non-member's target to the same nothing.
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp mount_org_billing(socket, org, user) do
    # ensure_wallet is the system seam (idempotent); the facts ride the
    # runway projection (balance included — the dashboard's source, the
    # personal page's posture), the org resolved from the URL.
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, runway} = Billing.compute_runway(wallet)

    page = ledger_page(wallet.id, user)

    socket =
      socket
      |> stream(:entries, page.results)
      |> assign(
        org: org,
        wallet: wallet,
        runway: runway,
        page: page,
        history_empty?: page.results == []
      )

    {:ok, socket}
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
      bare
    >
      <%!-- App-wide grammar page (S9): `bare` main + .appgram — the page
      owns ALL of main's rhythm. The band is the org's wallet: the org's
      name rides the band's eyebrow (the S6 identity posture, no second
      mark block), the h1 stays "Billing" — the heading outline never
      collides with the org home's (the S8 muted-prefix lesson, avoided
      outright). No straddle. --%>
      <div class="appgram contents">
        <%!-- 1. The org wallet band. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <%!-- The band shape the personal billing page set (S9):
              identity left, the top-up CTA right — the wizard it
              opens bills THIS org's wallet (#408). --%>
              <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
                <div class="min-w-0">
                  <p class="eyebrow">{@org.name}</p>
                  <h1 class="page-title mt-1.5">Billing</h1>
                  <p class="mt-2 text-base text-ink-muted">
                    A prepaid wallet funds {@org.name}'s instances.
                  </p>
                </div>

                <div class="flex shrink-0 gap-2">
                  <.button
                    navigate={~p"/organizations/#{@org.slug}/billing/topup"}
                    variant="secondary"
                    id="add-credits"
                  >
                    Top up wallet
                  </.button>
                </div>
              </div>

              <div class="mt-9">
                <BillingComponents.wallet_facts facts={@runway} />
              </div>
            </div>
          </div>
        </section>

        <%!-- 2. The ledger — the S4/S6 section shape (the personal
        page's posture): heading outside the card, container-level rise
        (stream patches rewrite rows in place; node identity is what
        the rise rides). --%>
        <section aria-labelledby="org-billing-history-title" class="wrap pt-10 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <h2 id="org-billing-history-title" class="text-lg font-semibold tracking-tight text-ink">
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
