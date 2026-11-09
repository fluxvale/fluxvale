defmodule FluxValeWeb.AdminLive.Gateways do
  @moduledoc """
  The admin access-gateways surface (#501): every gateway the console
  can legally see in one table, read-only by design (the v1 plan made
  gateways/domains oversight; registration, keys, and config belong to
  the product surfaces — the org Access panel and the provider API).

  The honesty the surface can offer is bounded by its read policy:
  `AccessGateway` reads are members-only (`relates_to_actor_via`
  [:organization, :members]) with NO platform-admin arm — unlike the
  wallet seam the orgs surface rides. `relates_to_actor_via` is a
  FILTER, so a non-member admin's read answers `[]`, not Forbidden:
  this list is exactly the gateways of orgs the admin belongs to. The
  empty state says that in its title (filter-scoped, never a global
  claim), and for an admin with no org memberships at all (only
  producible by bypassing the create's JIT personal org) a scope note
  says why the list is empty instead. Widening the read policy is a
  policy change this lane does not make — the gap is reported, not
  built around (#613).

  Columns the policies admit: the org name (the flagged `:admin_lookup`
  seam, the lane's one org path), the identifier grammar the product
  uses (`fv-<8 hex>` + the tailnet domain, ADR-0039 §1), the state (the
  product's own vocabulary, rendered through the section's shared badge
  in AdminComponents with a shape cue per state), the rate snapshot,
  the created stamp. The credential references stay off the list: they
  render on the detail page, as names, with the copy that keeps them
  honest.

  Attention first: a gateway whose STATE is `:needs_attention` pins to
  the top, then newest created. The pin keys on the state, not the
  `needs_attention_since` stamp — Suspend does not clear that stamp, so
  a stamp-keyed sort would pin a suspended row indefinitely (the review
  finding; the domain-side fix is #613, not ours). The list is
  paginated by the shared data table (the latest-100 cap retired into
  real pagination; offset mode). Search narrows by hostname or
  org name/slug — the relationship filter runs at the data layer, so
  the search never needs an org read.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.Components.AdminDataTable

  require Ash.Query
  require Ash.Expr

  # The data table's contract (#501): the sortable fields are the
  # columns the row prints that the gateway read carries. Offset mode
  # (no keyset action on this read). The org name is NOT sortable: it
  # rides the flagged :admin_lookup seam after the read, not a column
  # of it.
  @sortable [:hostname, :state, :monthly_cents, :created_at]
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
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    trimmed = String.trim(query)
    state = %{socket.assigns.table | query: trimmed, page: 1}

    push_view(socket, state)
  end

  # A crafted query that is not a string is a no-op, not a crash.
  def handle_event("search", _params, socket), do: {:noreply, socket}

  # The header sort: whitelisted fields only, click-to-toggle. The
  # page resets with the order, so a stale deep link cannot land past
  # the new end.
  @impl Phoenix.LiveView
  def handle_event("sort", %{"field" => raw_field}, socket) do
    sort = AdminDataTable.toggle_sort(socket.assigns.table.sort, raw_field, @sortable)
    state = %{socket.assigns.table | sort: sort, page: 1}

    push_view(socket, state)
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

  # Every table event is a patch: the URL states the view, and
  # handle_params owns the re-query. replace keeps the browser
  # history clean — a table view is a state, not a navigation.
  defp push_view(socket, state) do
    {:noreply,
     push_patch(socket, to: AdminDataTable.url_for(~p"/admin/gateways", state), replace: true)}
  end

  # -- reads ----------------------------------------------------------------

  # Attention first, then newest provisioned. The pin is a STATE-keyed
  # expression sort (Ash.Expr.calc): needs_attention_since is written
  # by the state funnel but never cleared by Suspend, so a stamp-keyed
  # sort would pin a suspended row above a newer active one forever.
  # The page rides the shared data table: an honest count, then one
  # server-driven page. The org names ride the flagged lookup seam —
  # one read for the page's ids, mapped by id; a gateway whose org
  # vanished (the FK is :restrict, so this cannot happen today) would
  # simply render without a name.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user
    state = socket.assigns.table

    filtered =
      AccessGateway
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> maybe_search(state.query)

    total = Ash.count!(filtered)
    page_count = AdminDataTable.page_count(total, state.size)

    page_query =
      filtered
      |> apply_sort(state.sort)
      |> Ash.Query.limit(state.size)
      |> Ash.Query.offset((state.page - 1) * state.size)

    rows = Ash.read!(page_query)

    # A stale deep link (rows left the window between visits) lands
    # past the end: clamp to the last page, once.
    {gateways, page} = clamp_page(rows, state.page, page_count, page_query, state.size)

    updated = %{state | page: page, total: total}

    socket
    |> assign(
      table: updated,
      orgs: org_lookup(admin, gateways),
      any_membership?: any_membership?(admin),
      rows_empty?: gateways == []
    )
    |> stream(:gateways, gateways, reset: true)
  end

  defp clamp_page(rows, page, page_count, _page_query, _size) when page <= page_count do
    {rows, page}
  end

  defp clamp_page(_empty, _page, page_count, page_query, size) do
    last_offset = (page_count - 1) * size

    rows =
      page_query
      |> Ash.Query.offset(last_offset)
      |> Ash.read!()

    {rows, page_count}
  end

  # The default order is the attention-pin expression sort; the id
  # tiebreak rides every sort so a same-second page boundary cannot
  # shuffle rows between reads.
  defp apply_sort(query, nil) do
    Ash.Query.sort(query, [
      {Ash.Expr.calc(state == :needs_attention), :desc},
      {:created_at, :desc},
      {:id, :desc}
    ])
  end

  # Whitelisted atoms only — the param path never builds a sort term.
  defp apply_sort(query, {field, dir}) do
    Ash.Query.sort(query, [{field, dir}, {:id, :desc}])
  end

  defp maybe_search(query, ""), do: query

  # The scope filter, drawn in data: hostname (the row's identifier) or
  # org name/slug (whose gateway it is), nothing past it. The
  # relationship filter runs at the data layer — no Organization read
  # rides the search.
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
      ilike(hostname, ^pattern) or
        exists(organization, ilike(name, ^pattern)) or
        exists(organization, ilike(slug, ^pattern))
    )
  end

  defp org_lookup(_admin, []), do: %{}

  defp org_lookup(admin, gateways) do
    organization_ids = Enum.map(gateways, & &1.organization_id)
    ids = Enum.uniq(organization_ids)

    {:ok, orgs} =
      Organization
      |> Ash.ActionInput.for_action(:admin_lookup, %{ids: ids}, actor: admin)
      |> Ash.run_action()

    Map.new(orgs, fn org -> {org.id, org} end)
  end

  # The membership probe (the orgs slice's, generalized to "any"): the
  # Membership read policy is members-only with the same
  # relates_to_actor_via filter, so a non-member admin's read answers
  # [] — the policy's own "you are not inside" answer. No new action,
  # no widened policy. It serves ONLY the org-less shape (a seeded
  # service account): a product-created admin always carries the JIT
  # personal org, so the main empty state stays filter-scoped and never
  # leans on this.
  defp any_membership?(admin) do
    Membership
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(user_id == ^admin.id)
    |> Ash.read!()
    |> Enum.any?()
  end

  # -- display helpers ------------------------------------------------------

  # The :error arms are the vanished-org guard (the gateway FK is
  # :restrict, so the org cannot be gone while the gateway stands) —
  # not simulatable without dropping the constraint.
  defp org_name(orgs, gateway) do
    case Map.fetch(orgs, gateway.organization_id) do
      {:ok, org} -> org.name
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  defp org_slug(orgs, gateway) do
    case Map.fetch(orgs, gateway.organization_id) do
      {:ok, org} -> org.slug
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  # Reached only under the created_at guard in the template.
  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

  # The column declarations, built per render so the labels ride the
  # live locale. The two flexible columns declare their own floors:
  # the pledged #608 finding was exactly this table's floor riding
  # the fixed tracks alone, stranding the org and gateway columns —
  # the component's computed floor now reads every column's minimum.
  defp columns do
    [
      %{
        key: :org,
        label: gettext("Organization"),
        track: "minmax(0,1.5fr)",
        floor_rem: 7
      },
      %{
        key: :gateway,
        label: gettext("Gateway"),
        track: "minmax(0,1.2fr)",
        sort: :hostname,
        floor_rem: 8
      },
      %{key: :state, label: gettext("State"), track: "9.5rem", sort: :state},
      %{
        key: :rate,
        label: gettext("Rate"),
        track: "7.5rem",
        align: :right,
        sort: :monthly_cents
      },
      %{key: :created, label: gettext("Created"), track: "6.5rem", sort: :created_at},
      %{
        key: :actions,
        label: gettext("Actions"),
        track: "3.5rem",
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
      <div class="appgram console contents" data-testid="admin-gateways">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Access gateways and domains")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Private-access gateways and the domains that serve them. This page is read-only: registration and keys live on each org's Access panel."
                )}
              </p>
              <%!-- The one honesty statement the page carries: the read
              scope, stated at fact weight, not as a footnote (the orgs
              surface's treatment). --%>
              <p class="mt-1 max-w-prose text-sm font-medium text-ink">
                {gettext(
                  "Gateway reads are member-scoped, so this list is the gateways of orgs you belong to."
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
            <AdminShell.sidebar current="gateways" pending_requests={@pending_storage_requests} />

            <div class="min-w-0 flex-1 space-y-6">
              <.card class="space-y-4" data-testid="admin-gateways-search-card">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Find a gateway")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "Search narrows this list by hostname or org name or slug. It never reaches past it."
                    )}
                  </p>
                </div>
                <.form
                  for={@search_form}
                  id="admin-gateways-search"
                  phx-change="search"
                  phx-submit="search"
                >
                  <.input
                    field={@search_form[:query]}
                    type="text"
                    label={gettext("Hostname or org")}
                    placeholder={gettext("Search by hostname or org name or slug")}
                    phx-debounce="200"
                    data-testid="admin-gateways-search-input"
                  />
                </.form>
              </.card>

              <div class="space-y-4" data-testid="admin-gateways-list">
                <%!-- The empty states ride the lane's panel-inset shape
                (the scope note's card, the #571/#603 treatment) — no
                dashed boxes on this surface, dark mode included. The
                MAIN empty is filter-scoped: the member-scoped read
                cannot support a global claim, so the title names the
                orgs this admin belongs to and only the copy carries
                the once-enabled story. --%>
                <div
                  :if={@rows_empty? and @table.query == "" and @any_membership?}
                  class="rounded-panel border border-line bg-panel px-4 py-3"
                  data-testid="admin-gateways-empty"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("No gateways in the orgs you belong to.")}
                  </p>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "Private access is opt-in per org. An org's gateway appears here once its owner enables it."
                    )}
                  </p>
                </div>

                <%!-- The honest scope note: a members-only read cannot
                tell "no gateways anywhere" from "not yours to see", so
                the membership probe answers and the page states which
                emptiness this is (the orgs slice's discipline). --%>
                <div
                  :if={@rows_empty? and @table.query == "" and not @any_membership?}
                  class="rounded-panel border border-line bg-panel px-4 py-3"
                  data-testid="admin-gateways-scope-note"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("You are not a member of any org.")}
                  </p>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext("Gateways are readable by org members only, so none are listed here.")}
                  </p>
                </div>

                <div
                  :if={@rows_empty? and @table.query != ""}
                  class="rounded-panel border border-line bg-panel px-4 py-3"
                  data-testid="admin-gateways-search-empty"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("No gateway matches that search.")}
                  </p>
                </div>

                <%!-- The data table (#501): the shared component owns
                the chrome, the computed floor (the pledged #608
                finding: this list's floor now reads every column's
                minimum, not the fixed tracks alone), the sort
                headers, and the pagination. --%>
                <div :if={not @rows_empty?}>
                  <AdminDataTable.data_table
                    id="admin-gateways-table"
                    items={@streams.gateways}
                    columns={@columns}
                    meta={table_meta(@table)}
                  >
                    <:cell :let={gateway} col={:org}>
                      <div data-testid={"admin-gateways-org-#{gateway.id}"}>
                        <p class="truncate font-medium text-ink">{org_name(@orgs, gateway)}</p>
                        <p class="truncate font-mono text-xs text-ink-muted">
                          {org_slug(@orgs, gateway)}
                        </p>
                      </div>
                    </:cell>

                    <:cell :let={gateway} col={:gateway}>
                      <div data-testid={"admin-gateways-host-#{gateway.id}"}>
                        <p class="truncate font-mono text-sm text-ink">{gateway.hostname}</p>
                        <p class="truncate font-mono text-xs text-ink-muted">
                          {gateway.tailnet_domain}
                        </p>
                      </div>
                    </:cell>

                    <:cell :let={gateway} col={:state}>
                      <span data-testid={"admin-gateways-state-#{gateway.id}"}>
                        <AdminComponents.gateway_state_badge state={gateway.state} />
                      </span>
                    </:cell>

                    <:cell :let={gateway} col={:rate}>
                      <span
                        class="whitespace-nowrap text-sm tabular-nums text-ink"
                        data-testid={"admin-gateways-rate-#{gateway.id}"}
                      >
                        {Pricing.format_usd(gateway.monthly_cents)}
                        <span class="text-xs font-normal text-ink-muted">
                          {gettext("per month")}
                        </span>
                      </span>
                    </:cell>

                    <:cell :let={gateway} col={:created}>
                      <span
                        :if={gateway.created_at}
                        class="text-sm text-ink-muted"
                        data-testid={"admin-gateways-created-#{gateway.id}"}
                      >
                        {stamp_text(gateway.created_at)}
                      </span>
                    </:cell>

                    <:cell :let={gateway} col={:actions}>
                      <div class="flex items-center justify-end">
                        <.link
                          navigate={~p"/admin/gateways/#{gateway.id}"}
                          data-testid={"admin-gateways-open-#{gateway.id}"}
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
