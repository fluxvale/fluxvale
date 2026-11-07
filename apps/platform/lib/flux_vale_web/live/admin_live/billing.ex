defmodule FluxValeWeb.AdminLive.Billing do
  @moduledoc """
  The admin wallets surface (#501): every org's wallet in one table,
  org-first per the domain's stated operator contract (Wallet's admin
  block: organization, balance, paywall_waived, negative_since). The
  balance is the live ledger sum aggregate, never a column.
  `negative_since` is the destroy clock's anchor (#124): a row carrying
  it is a countdown, and the table renders it as one.

  Every read rides the billing domain with the platform-admin actor and
  authorization on. Search narrows the list by org name or slug — the
  relationship filter runs at the data layer, so the search never needs
  an org read. Rendering the org column DOES: the read policy is
  members-only, so the names ride `Organization :admin_lookup`, the
  flagged seam this lane added (#501 — the only admin-readable org
  path, returning the switcher's public fields).

  The list caps at the latest 100 (the people surface's rationale: an
  unbounded scan grows expensive and the operator scans for what just
  happened anyway). Revisit trigger: pagination once wallet volume
  approaches the cap.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Wallet
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.BillingComponents

  require Ash.Query
  require Ash.Expr

  # The list cap (the moduledoc names it; move the two together): an
  # unbounded read is an unindexed sort away from growing expensive,
  # and the operator finds a wallet by search, not by paging. Revisit
  # trigger: pagination once wallet volume approaches the cap.
  @list_cap 100

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own data.
    {:ok,
     socket
     |> assign(query: "")
     |> assign(search_form: to_form(%{"query" => ""}, as: :search))
     |> refresh_rows()}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    trimmed = String.trim(query)

    {:noreply,
     socket
     |> assign(query: trimmed, search_form: to_form(%{"query" => trimmed}, as: :search))
     |> refresh_rows()}
  end

  # -- reads ----------------------------------------------------------------

  # Attention first: the destroy-clock rows pin to the top (by anchor
  # recency), then newest provisioned — a long-standing org that just
  # went negative must not sink under fresh signups. Capped one past
  # the cap so the overflow question answers without a count. The org
  # names ride the flagged lookup seam — one read for the page's ids,
  # mapped by id; a wallet whose org vanished (the FK has no ON DELETE,
  # so this cannot happen today) would simply render without a name.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user

    fetched =
      Wallet
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.sort(negative_since: :desc_nils_last, created_at: :desc, id: :desc)
      |> maybe_search(socket.assigns.query)
      |> Ash.Query.limit(@list_cap + 1)
      |> Ash.Query.load(:balance)
      |> Ash.read!()

    capped? = length(fetched) > @list_cap
    wallets = Enum.take(fetched, @list_cap)

    socket
    |> assign(
      orgs: org_lookup(admin, wallets),
      rows_empty?: wallets == [],
      rows_capped?: capped?
    )
    |> stream(:wallets, wallets, reset: true)
  end

  defp maybe_search(query, ""), do: query

  # The scope filter, drawn in data: org name or org slug (the org's
  # address), nothing past it. The relationship filter runs at the data
  # layer — no Organization read rides the search.
  defp maybe_search(query, term) do
    # ILIKE wildcards in the term are literals: escaped before the
    # pattern wraps both ends (the backslash first, or it would
    # double-escape the ones below).
    escaped =
      term
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "%#{escaped}%"

    # Non-keyword call form: filter/2 routes it through Ash.Expr.expr,
    # where the exists()/ilike() calls and the relationship path parse
    # as one filter. (The keyword-list form bypasses expr and would
    # compile the calls as plain Elixir.)
    Ash.Query.filter(
      query,
      exists(organization, ilike(name, ^pattern)) or
        exists(organization, ilike(slug, ^pattern))
    )
  end

  defp org_lookup(_admin, []), do: %{}

  defp org_lookup(admin, wallets) do
    organization_ids = Enum.map(wallets, & &1.organization_id)
    ids = Enum.uniq(organization_ids)

    {:ok, orgs} =
      Organization
      |> Ash.ActionInput.for_action(:admin_lookup, %{ids: ids}, actor: admin)
      |> Ash.run_action()

    Map.new(orgs, fn org -> {org.id, org} end)
  end

  # -- display helpers ------------------------------------------------------

  # The :error arms are the vanished-org guard (the wallet FK has no
  # ON DELETE, so the org cannot be gone while the wallet stands) —
  # not simulatable without dropping the constraint.
  defp org_name(orgs, wallet) do
    case Map.fetch(orgs, wallet.organization_id) do
      {:ok, org} -> org.name
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  defp org_slug(orgs, wallet) do
    case Map.fetch(orgs, wallet.organization_id) do
      {:ok, org} -> org.slug
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  # The danger presentation gates on the balance alone: the sweep
  # clears a recovered wallet's anchor hourly, and an armed-but-positive
  # row must not read as a countdown.
  defp negative?(wallet), do: wallet.balance < 0

  # The waiver badge grammar: waived is the live switch (primary, the
  # key as the non-color cue), off rests neutral with no cue — the same
  # tone-and-shape discipline as the people surface's states.
  defp waiver_tone(true), do: "primary"
  defp waiver_tone(false), do: "neutral"

  defp waiver_label(true), do: gettext("Waived")
  defp waiver_label(false), do: gettext("Not waived")

  # Reached only under the negative_since guard in the template.
  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

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
      <div class="appgram contents" data-testid="admin-billing">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Wallets and billing")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Every org's wallet. The balance is the ledger, a row with the destroy clock is a countdown, and the waiver moves no money. Open a wallet for its ledger and the writes."
                )}
              </p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin"}
                  data-testid="admin-billing-back-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to the admin console")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-8">
          <%!-- The search card rides the same two-column proportion the
          people surface set. --%>
          <div class="rise grid items-start gap-6 lg:grid-cols-2">
            <.card class="space-y-4" data-testid="admin-billing-search-card">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("Find a wallet")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext("Search narrows this list by org name or slug. It never reaches past it.")}
                </p>
              </div>
              <.form
                for={@search_form}
                id="admin-billing-search"
                phx-change="search"
                phx-submit="search"
              >
                <.input
                  field={@search_form[:query]}
                  type="text"
                  label={gettext("Org name or slug")}
                  placeholder={gettext("Search by org name or slug")}
                  phx-debounce="200"
                  data-testid="admin-billing-search-input"
                />
              </.form>
            </.card>
          </div>
        </section>

        <section class="wrap pt-4 pb-16">
          <div class="rise space-y-4" data-testid="admin-billing-list">
            <%!-- The count is the @list_cap above (kept literal here —
            a module attribute reads as assigns inside HEEx); move the
            two together. --%>
            <p :if={@rows_capped?} class="text-sm text-ink-muted" data-testid="admin-billing-capped">
              {gettext("Showing the latest 100 wallets. Negative balances pin to the top.")}
            </p>

            <.empty_state :if={@rows_empty? and @query == ""} title={gettext("No wallets yet.")}>
              {gettext(
                "Every org carries exactly one wallet, provisioned on demand. Open one to see its ledger."
              )}
            </.empty_state>

            <.empty_state
              :if={@rows_empty? and @query != ""}
              title={gettext("No wallet matches that org.")}
            />

            <div
              :if={not @rows_empty?}
              class="overflow-x-auto rounded-panel border border-line bg-panel text-ink"
            >
              <div class="min-w-[56rem]">
                <%!-- One grid template shared by the header and every
                row (kept literal in both spots), so the columns can
                never drift. --%>
                <div class="grid grid-cols-[minmax(14rem,2fr)_8rem_9rem_minmax(11rem,1.5fr)_5rem] items-center gap-x-2 border-b border-line px-4 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
                  <div>{gettext("Organization")}</div>
                  <div class="text-right">{gettext("Balance")}</div>
                  <div>{gettext("Paywall waiver")}</div>
                  <div>{gettext("Negative since")}</div>
                  <div class="sr-only">{gettext("Actions")}</div>
                </div>

                <div id="admin-billing-table" phx-update="stream">
                  <div
                    :for={{dom_id, wallet} <- @streams.wallets}
                    id={dom_id}
                    class={[
                      "grid grid-cols-[minmax(14rem,2fr)_8rem_9rem_minmax(11rem,1.5fr)_5rem] items-center gap-x-2 border-b border-line px-4 py-3 transition-colors last:border-0 hover:bg-panel-raised/60",
                      negative?(wallet) && "bg-danger-muted"
                    ]}
                  >
                    <div class="min-w-0" data-testid={"admin-billing-org-#{wallet.id}"}>
                      <.link
                        :if={org_name(@orgs, wallet)}
                        navigate={~p"/admin/billing/wallets/#{wallet.id}"}
                        class="block truncate font-medium text-ink hover:text-link"
                        data-testid={"admin-billing-org-link-#{wallet.id}"}
                      >
                        {org_name(@orgs, wallet)}
                      </.link>
                      <p class="truncate font-mono text-xs text-ink-muted">
                        {org_slug(@orgs, wallet)}
                      </p>
                    </div>
                    <div class="text-right">
                      <span
                        class={[
                          "whitespace-nowrap text-sm tabular-nums",
                          wallet.balance < 0 && "font-semibold text-danger"
                        ]}
                        data-testid={"admin-billing-balance-#{wallet.id}"}
                      >
                        {BillingComponents.format_balance(wallet.balance)}
                      </span>
                    </div>
                    <div>
                      <span data-testid={"admin-billing-waiver-#{wallet.id}"}>
                        <.badge tone={waiver_tone(wallet.paywall_waived)}>
                          <.icon
                            :if={wallet.paywall_waived}
                            name="hero-key"
                            class="size-3.5"
                          />
                          {waiver_label(wallet.paywall_waived)}
                        </.badge>
                      </span>
                    </div>
                    <%!-- The destroy clock (#124): the badge carries the
                    non-color cue (tone plus clock), the tint above
                    carries the weight, and the dates name the anchor
                    AND the deadline, so the countdown reads as one. --%>
                    <div>
                      <span
                        :if={negative?(wallet)}
                        class="inline-flex flex-col gap-0.5"
                        data-testid={"admin-billing-negative-#{wallet.id}"}
                      >
                        <.badge tone="danger" class="self-start">
                          <.icon name="hero-clock" class="size-3.5" />
                          <span>{gettext("Destroy clock")}</span>
                        </.badge>
                        <span
                          :if={wallet.negative_since}
                          class="whitespace-nowrap text-xs text-ink-muted"
                        >
                          {gettext("since %{start}, deletes %{deadline}",
                            start: stamp_text(wallet.negative_since),
                            deadline: AdminComponents.destroy_deadline_text(wallet.negative_since)
                          )}
                        </span>
                      </span>
                    </div>
                    <div>
                      <div class="flex items-center justify-end">
                        <.link
                          navigate={~p"/admin/billing/wallets/#{wallet.id}"}
                          data-testid={"admin-billing-open-#{wallet.id}"}
                          class="text-sm font-medium text-link underline-offset-2 hover:underline"
                        >
                          {gettext("Open")}
                        </.link>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
