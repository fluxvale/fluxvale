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

  The list is paginated by the shared data table (the latest-100 cap
  retired into real pagination; offset mode — the wallet read has no
  keyset action). The org names ride the flagged lookup seam — one
  read for the page's ids, mapped by id.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Wallet
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.BillingComponents
  alias FluxValeWeb.Components.AdminDataTable

  require Ash.Query
  require Ash.Expr

  # The data table's contract (#501): the sortable fields are the
  # columns the row prints that the wallet read carries — the live
  # balance (a sum aggregate, sortable at the data layer), the
  # countdown anchor, and provisioning recency. The org name is NOT
  # sortable: it rides the flagged :admin_lookup seam after the read,
  # not a column of it. Offset mode (no keyset action on this read).
  @sortable [:balance, :negative_since, :created_at]
  @sizes AdminDataTable.default_sizes()

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own non-table data. The table's view state is
    # handle_params' business (the URL is the source of truth).
    {:ok, socket}
  end

  # The URL states the table's view: sort, page, size, and the search
  # term ride query params, parsed with garbage-proof fallbacks.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    state = AdminDataTable.parse_params(params, sortable: @sortable)

    {:noreply,
     socket
     |> assign(
       table: state,
       columns: columns(),
       search_form: to_form(%{"query" => state.query}, as: :search)
     )
     |> refresh_rows()}
  end

  # -- events ---------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket) when is_binary(query) do
    state = %{socket.assigns.table | query: AdminDataTable.cap_query(query), page: 1}

    push_view(socket, state)
  end

  # A crafted query that is not a string is a no-op, not a crash.
  def handle_event("search", _params, socket), do: {:noreply, socket}

  # The header sort: whitelisted fields only, click-to-toggle. The
  # page resets with the order, so a stale deep link cannot land past
  # the new end. A crafted field leaves the sort as it was: a true
  # no-op, no page reset, no patch.
  @impl Phoenix.LiveView
  def handle_event("sort", %{"field" => raw_field}, socket) do
    sort = AdminDataTable.toggle_sort(socket.assigns.table.sort, raw_field, @sortable)

    if sort == socket.assigns.table.sort do
      {:noreply, socket}
    else
      push_view(socket, %{socket.assigns.table | sort: sort, page: 1})
    end
  end

  # A crafted field is not a crash: the sort stays as it was.
  def handle_event("sort", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("page", %{"nav" => "prev"}, socket) do
    state = %{socket.assigns.table | page: socket.assigns.table.page - 1}

    push_view(socket, state)
  end

  def handle_event("page", %{"nav" => "next"}, socket) do
    state = %{socket.assigns.table | page: socket.assigns.table.page + 1}

    push_view(socket, state)
  end

  # A crafted page event is a no-op.
  def handle_event("page", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("size", %{"size" => raw}, socket) do
    size = AdminDataTable.parse_size(raw)
    state = %{socket.assigns.table | size: size, page: 1}

    push_view(socket, state)
  end

  def handle_event("size", _params, socket), do: {:noreply, socket}

  # The search-empty state's clear lever: the same view, term gone.
  @impl Phoenix.LiveView
  def handle_event("clear-search", _params, socket) do
    state = %{socket.assigns.table | query: "", page: 1}

    push_view(socket, state)
  end

  # Every table event is a patch: the URL states the view, and
  # handle_params owns the re-query. replace keeps the browser
  # history clean — a table view is a state, not a navigation.
  defp push_view(socket, state) do
    {:noreply,
     push_patch(socket, to: AdminDataTable.url_for(~p"/admin/billing", state), replace: true)}
  end

  # -- reads ----------------------------------------------------------------

  # Attention first: the destroy-clock rows pin to the top (by anchor
  # recency), then newest provisioned — a long-standing org that just
  # went negative must not sink under fresh signups. The page rides
  # the shared data table: an honest count, then one server-driven
  # page. The org names ride the flagged lookup seam — one read for
  # the page's ids, mapped by id; a wallet whose org vanished (the FK
  # has no ON DELETE, so this cannot happen today) would simply render
  # without a name.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user
    state = socket.assigns.table

    filtered =
      Wallet
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> maybe_search(state.query)

    total = Ash.count!(filtered)
    page_count = AdminDataTable.page_count(total, state.size)

    # A crafted deep link clamps BEFORE the query is built: the page
    # read runs at the honest offset, never a crafted deep scan.
    page = min(state.page, page_count)

    wallets =
      filtered
      |> apply_sort(state.sort)
      |> Ash.Query.load(:balance)
      |> Ash.Query.limit(state.size)
      |> Ash.Query.offset((page - 1) * state.size)
      |> Ash.read!()

    updated = %{state | page: page, total: total}

    socket
    |> assign(
      table: updated,
      orgs: org_lookup(admin, wallets),
      rows_empty?: wallets == []
    )
    |> stream(:wallets, wallets, reset: true)
  end

  # The default order is the attention-first expression sort; the id
  # tiebreak rides every sort so a same-second page boundary cannot
  # shuffle rows between reads.
  defp apply_sort(query, nil) do
    Ash.Query.sort(query, negative_since: :desc_nils_last, created_at: :desc, id: :desc)
  end

  # Whitelisted atoms only — the param path never builds a sort term.
  defp apply_sort(query, {field, dir}) do
    Ash.Query.sort(query, [{field, dir}, {:id, :desc}])
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

  # The column declarations, built per render so the labels ride the
  # live locale. The tracks and floors are the shared component's
  # data: the flexible columns declare their own floor so the
  # computed min-width cannot strand them (the #608 review's finding,
  # owned once in the component).
  defp columns do
    [
      %{
        key: :org,
        label: gettext("Organization"),
        track: "minmax(7.5rem,1.6fr)",
        floor_rem: 7.5
      },
      %{key: :balance, label: gettext("Balance"), track: "5.5rem", align: :right, sort: :balance},
      %{key: :waiver, label: gettext("Waiver"), track: "6.5rem"},
      %{
        key: :negative,
        label: gettext("Negative since"),
        track: "minmax(8.5rem,1.2fr)",
        sort: :negative_since,
        floor_rem: 8.5
      },
      %{
        key: :actions,
        label: gettext("Actions"),
        track: "3rem",
        align: :right,
        sr_only: true
      }
    ]
  end

  # The view state the component renders: the parsed params plus the
  # honest count and the surface's event names.
  defp table_meta(state) do
    %{
      query: state.query,
      page: state.page,
      size: state.size,
      sort: state.sort,
      total: state.total,
      sizes: @sizes,
      sort_event: "sort",
      page_event: "page",
      size_event: "size"
    }
  end

  # The countdown rows' tint rides the component's row_class fn.
  defp row_tint(wallet) do
    if negative?(wallet), do: "bg-danger-muted"
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
      wide
    >
      <%!-- The console lane (#593): `wide` chrome + `appgram console`
      - flush sidebar, the surface fills the space beside it. --%>
      <div class="appgram console contents" data-testid="admin-billing">
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
            </div>
          </div>
        </section>

        <%!-- The section sidebar (Am. 4, the #568 idiom) owns
        cross-section wayfinding — no console-level back link. The
        search card and the list are one content column beside it. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="wallets" pending_requests={@pending_storage_requests} />

            <div class="min-w-0 flex-1 space-y-6">
              <.card class="space-y-4" data-testid="admin-billing-search-card">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Find a wallet")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "Search narrows this list by org name or slug. It never reaches past it."
                    )}
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

              <div class="space-y-4" data-testid="admin-billing-list">
                <.empty_state
                  :if={@rows_empty? and @table.query == ""}
                  title={gettext("No wallets yet.")}
                >
                  {gettext(
                    "Every org carries exactly one wallet, provisioned on demand. Open one to see its ledger."
                  )}
                </.empty_state>

                <div
                  :if={@rows_empty? and @table.query != ""}
                  class="rounded-panel border border-line bg-panel px-6 py-8"
                  data-testid="admin-billing-search-empty"
                >
                  <.empty_state
                    title={gettext("No wallet matches that org.")}
                    class="border-none bg-transparent"
                  >
                    <.button
                      variant="secondary"
                      size="sm"
                      phx-click="clear-search"
                      data-testid="admin-billing-clear-search"
                    >
                      {gettext("Clear search")}
                    </.button>
                  </.empty_state>
                </div>

                <%!-- The data table (#501): the shared component owns
                the chrome, the tracks, the floor, the sort headers,
                and the pagination. The stream items ARE the rows, so
                the countdown tint rides the row_class fn; the
                per-row testids survive inside the cells. --%>
                <div :if={not @rows_empty?}>
                  <AdminDataTable.data_table
                    id="admin-billing-table"
                    items={@streams.wallets}
                    columns={@columns}
                    meta={table_meta(@table)}
                    row_class={&row_tint/1}
                  >
                    <:cell :let={wallet} col={:org}>
                      <div data-testid={"admin-billing-org-#{wallet.id}"}>
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
                    </:cell>

                    <:cell :let={wallet} col={:balance}>
                      <span
                        class={[
                          "whitespace-nowrap text-sm tabular-nums",
                          wallet.balance < 0 && "font-semibold text-danger-deep"
                        ]}
                        data-testid={"admin-billing-balance-#{wallet.id}"}
                      >
                        {BillingComponents.format_balance(wallet.balance)}
                      </span>
                    </:cell>

                    <:cell :let={wallet} col={:waiver}>
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
                    </:cell>

                    <%!-- The destroy clock (#124): the badge carries the
                    non-color cue (tone plus clock), the tint above
                    carries the weight, and the dates name the anchor
                    AND the deadline, so the countdown reads as one. --%>
                    <:cell :let={wallet} col={:negative}>
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
                          class="flex flex-col text-xs text-ink-muted"
                        >
                          <span>
                            {gettext("since %{date}",
                              date: stamp_text(wallet.negative_since)
                            )}
                          </span>
                          <span>
                            {gettext("deletes %{date}",
                              date: AdminComponents.destroy_deadline_text(wallet.negative_since)
                            )}
                          </span>
                        </span>
                      </span>
                    </:cell>

                    <:cell :let={wallet} col={:actions}>
                      <div class="flex items-center justify-end">
                        <.link
                          navigate={~p"/admin/billing/wallets/#{wallet.id}"}
                          data-testid={"admin-billing-open-#{wallet.id}"}
                          class="text-sm font-medium text-link underline-offset-2 hover:underline"
                        >
                          {gettext("Open")}
                        </.link>
                      </div>
                    </:cell>
                  </AdminDataTable.data_table>
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
