defmodule FluxValeWeb.AdminLive.Audit do
  @moduledoc """
  The Audit section (#645, ADR-0048 — the trail's window): one
  cross-resource view over the business set's version rows. Every
  mutation on the 31 business resources writes an attributed version
  row; this surface is where an operator reads them.

  The browsable set is `FluxValeWeb.AdminAudit`'s list (the parity
  seam with the doctrine gate). Each read queries the selected
  resource's Version module through its DOMAIN with the mount-resolved
  admin actor and authorization ON (repo default) — the mixin's
  direct admin-only read policy (D7) decides, never the UI.

  The table rides the shared data table (#501, `AdminDataTable`):
  sort, page, and page size ride query params, so a URL states the
  view and reloading lands on it. The default order is newest first
  on the version's own stamp (`version_inserted_at`), with the id
  tiebreak; the component footer owns the honest count and the pager.
  There is no search box: this read has no free-text contract — the
  exact filters are.

  Filters ride query params: `?resource=<key>` picks the resource
  (unknown segments bounce to the default honestly, the registry's
  posture), `?actor=<label>` exact-matches the denormalized actor
  tombstone (no joins — the label rides the row) with the literal
  "System" naming the nil tombstone itself (the system-writes
  filter), and `?source=<uuid>` narrows one record's history (the
  engine show pages' History deep link). A source that is not
  UUID-shaped bounces with an honest flash — garbage never reaches
  the query. A label carrying control bytes (the NUL shape — the
  byte the query layer refuses) filters nothing, the empty-value
  posture.

  The rows render the tombstone as recorded: a nil `actor_label` is
  the honest system attribution and says so, REDACTED markers in
  `changes` render verbatim (that a sensitive attribute exists is the
  record — the value never shipped), and a destroy keeps its row (the
  row names the record it retired — the id survives, the reference
  does not, D6). Every row NAMES its record: the
  `version_source_id` renders as the engine's short id, linked to the
  record-history view, and the actor tombstone links its own filter —
  the drill-down grammar. Unknown anything bounces; nothing is
  guessed.

  The bespoke numbered pagination retired with the adoption;
  `AdminResource.page_window/2` and `total_pages/2` went with it —
  #803 took the resources console's calls and this surface was the
  last caller, so the helpers are deleted (the #602 consolidation
  tail closes here, not in S4).
  """

  use FluxValeWeb, :live_view

  alias Ash.Resource.Info
  alias FluxValeWeb.AdminAudit
  alias FluxValeWeb.AdminResource
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.Components.AdminDataTable

  # The filters' expressions parse through Ash.Expr (the gateways
  # search's non-keyword call form) — the require is load-bearing.
  require Ash.Query

  # The data table's contract (#501): sort/page/size ride the shared
  # component, offset mode, and only these fields sort — the columns
  # the row prints that the version read carries. Record and changes
  # are not sortable (the record is a reference id, the changes a
  # rendered blob).
  @sortable [:version_inserted_at, :version_action_type, :version_action_name, :actor_label]
  @sizes AdminDataTable.default_sizes()

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The URL is the source of truth for the table's view: mount only
    # resolves the browsable set, handle_params parses the view.
    {:ok, assign(socket, entries: AdminAudit.entries())}
  end

  # The URL states the table's view: resource and filters resolve here
  # alongside sort, page, and size, parsed with garbage-proof
  # fallbacks.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    entries = socket.assigns.entries

    case pick_entry(entries, params["resource"]) do
      {:ok, entry} ->
        case source_filter(params["source"]) do
          {:ok, source} ->
            filters = %{actor: actor_filter(params["actor"]), source: source}

            socket
            |> assign(
              groups: groups(entries),
              entry: entry,
              filters: filters,
              actor: filters.actor,
              source: filters.source,
              filtered?: filters.actor != nil or filters.source != nil,
              columns: columns()
            )
            |> load_page(filters, params)

          :error ->
            # A non-UUID ?source= is a malformed deep link: garbage
            # never reaches the query, and the bounce keeps the
            # resource context (the honest-unknown posture).
            {:noreply,
             socket
             |> put_flash(:error, gettext("That history link is malformed."))
             |> push_navigate(to: audit_path(entry.key, nil, nil, 1))}
        end

      :error ->
        # A ?resource= segment that resolves against no entry can
        # never exist: bounce to the default with the console's honest
        # flash (the registry's unknown-segment posture).
        {:noreply,
         socket
         |> put_flash(:error, gettext("That page does not exist here."))
         |> push_navigate(to: ~p"/admin/audit")}
    end
  end

  # -- events ---------------------------------------------------------------

  # The header sort: whitelisted fields only, click-to-toggle. The page
  # resets with the order, so a stale deep link cannot land past the
  # new end.
  @impl Phoenix.LiveView
  def handle_event("sort", %{"field" => raw_field}, socket) do
    sort = AdminDataTable.toggle_sort(socket.assigns.table.sort, raw_field, @sortable)

    # A crafted field leaves the sort as it was: a true no-op, no page
    # reset, no patch.
    if sort == socket.assigns.table.sort do
      {:noreply, socket}
    else
      push_view(socket, %{socket.assigns.table | sort: sort, page: 1})
    end
  end

  # A crafted field is not a crash: the sort stays as it was.
  def handle_event("sort", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("page", %{"nav" => nav}, socket) when nav in ["prev", "next"] do
    table = socket.assigns.table
    total_pages = AdminDataTable.page_count(table.total, table.size)
    target = if nav == "prev", do: table.page - 1, else: table.page + 1

    # The bounds are the component's disabled states, enforced here
    # too: a crafted push never reads past either end.
    if target < 1 or target > total_pages do
      {:noreply, socket}
    else
      push_view(socket, %{table | page: target})
    end
  end

  # A crafted page event is a no-op.
  def handle_event("page", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("size", %{"size" => raw}, socket) do
    size = AdminDataTable.parse_size(raw, @sizes)

    push_view(socket, %{socket.assigns.table | size: size, page: 1})
  end

  def handle_event("size", _params, socket), do: {:noreply, socket}

  # Every table event is a patch: the URL states the view, and
  # handle_params owns the re-query. replace keeps the browser history
  # clean — a table view is a state, not a navigation. The surface's
  # filters ride every URL, so sort/page/size never drop them (the
  # shareable-view contract).
  defp push_view(socket, state) do
    {:noreply, push_patch(socket, to: view_url(socket, state), replace: true)}
  end

  defp view_url(socket, state) do
    AdminDataTable.url_for(
      ~p"/admin/audit",
      state,
      filters_extra(socket.assigns.entry, socket.assigns.filters)
    )
  end

  # -- reads ----------------------------------------------------------------

  # The count comes first and cheaply: one row's projection, no loads,
  # so the page math never reads a full page's rows.
  defp load_page(socket, filters, params) do
    state = AdminDataTable.parse_params(params, sortable: @sortable)
    admin = socket.assigns.current_user
    entry = socket.assigns.entry

    count = count_rows(entry, filters, admin)
    total_pages = AdminDataTable.page_count(count, state.size)

    if state.page > total_pages and count > 0 do
      # A page past the end bounces to the real last page (the
      # engine's honest-URL posture) — the filters ride along.
      {:noreply,
       push_navigate(socket,
         to:
           AdminDataTable.url_for(
             ~p"/admin/audit",
             %{state | page: total_pages},
             filters_extra(entry, filters)
           )
       )}
    else
      page = read_page(entry, filters, state, admin)
      table = %{state | total: count}

      {:noreply,
       socket
       |> assign(table: table, rows_empty?: page.results == [])
       |> stream(:versions, page.results, reset: true)}
    end
  end

  defp count_rows(entry, filters, actor) do
    page =
      entry
      |> section_query(filters, actor)
      |> Ash.read!(page: [limit: 1, offset: 0, count: true])

    page.count || 0
  end

  @doc """
  The section's version page for one entry: the Version module read
  through its domain with the actor riding the query and authorization
  ON (repo default), the view state's sort and offset. No count rides
  this read — `count_rows/3` already counted the same scope cheaply,
  and a discarded second count would double the query's work.
  Public seam: the version-read policy pin drives this exact path with
  a member actor — the Forbidden there is the mixin's answer through
  the section's own query, not a crafted side read.
  """
  @spec read_page(map(), map(), map(), term()) :: Ash.Page.Offset.t()
  def read_page(entry, filters, state, actor) do
    entry
    |> section_query(filters, actor)
    |> apply_sort(state.sort)
    |> Ash.read!(page: [limit: state.size, offset: (state.page - 1) * state.size])
  end

  defp section_query(entry, filters, actor) do
    module = AdminAudit.version_module(entry)

    module
    |> Ash.Query.for_read(primary_read(module), %{}, actor: actor)
    |> apply_filters(filters)
  end

  defp primary_read(module) do
    Info.primary_action(module, :read).name
  end

  # The tombstone makes the actor filter a column match — no joins.
  # The value compares exactly as recorded; the :system assign is the
  # nil tombstone's filter (the rows that recorded no actor at all).
  defp apply_filters(query, %{actor: actor, source: source}) do
    query
    |> apply_actor_filter(actor)
    |> apply_source_filter(source)
  end

  defp apply_actor_filter(query, nil), do: query

  defp apply_actor_filter(query, :system),
    do: Ash.Query.filter(query, is_nil(actor_label))

  defp apply_actor_filter(query, label), do: Ash.Query.filter(query, actor_label == ^label)

  defp apply_source_filter(query, nil), do: query

  defp apply_source_filter(query, source),
    do: Ash.Query.filter(query, version_source_id == ^source)

  # Newest first by default; the id tiebreak rides every sort so a
  # same-second page boundary cannot shuffle rows between reads. The
  # de-dupe keeps the tiebreak from doubling the id field when a
  # surface ever whitelists it.
  defp apply_sort(query, nil), do: Ash.Query.sort(query, version_inserted_at: :desc, id: :desc)

  # Whitelisted atoms only — the param path never builds a sort term.
  defp apply_sort(query, {field, dir}) do
    pairs = Enum.uniq_by([{field, dir}, {:id, :desc}], &elem(&1, 0))

    Ash.Query.sort(query, pairs)
  end

  # -- param hygiene ----------------------------------------------------------

  # The default resource is the list's first entry — the picker's own
  # order decides what a bare /admin/audit shows.
  defp pick_entry(entries, nil), do: {:ok, List.first(entries)}
  defp pick_entry(_entries, segment), do: AdminAudit.fetch(segment)

  defp actor_filter(nil), do: nil

  defp actor_filter(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> nil
      # The nil tombstone's own spelling: a real actor literally named
      # "System" is shadowed by the filter's param — the accepted
      # trade, labels are free text and params are not.
      "System" -> :system
      label -> if printable?(label), do: label, else: nil
    end
  end

  # A crafted non-binary ?actor= (the page[]= shape) filters nothing:
  # the view renders the honest full history rather than guessing at
  # an encoding.
  defp actor_filter(_not_a_string), do: nil

  # A label carrying control bytes (a NUL byte 500s the mount — the
  # value never reaches the query) takes the empty-value posture: it
  # filters nothing, no chip renders.
  defp printable?(label), do: String.printable?(label)

  # A ?source= must read as a UUID before it filters anything — the
  # engine's "an unknown id is data" posture, with the malformed shape
  # refused at the door (the mount bounces).
  defp source_filter(nil), do: {:ok, nil}

  defp source_filter(raw) when is_binary(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp source_filter(_not_a_string), do: :error

  # -- render helpers ---------------------------------------------------------

  # The picker's groups: the DISTINCT domains in first-occurrence
  # order, one group per domain. Chunking the display order would
  # split a domain's group the moment an entry appends out of chunk
  # adjacency — the list grows by appending, so the grouping must not
  # depend on it.
  defp groups(entries) do
    entries
    |> Enum.uniq_by(& &1.domain)
    |> Enum.map(fn first ->
      {domain_label(first.domain), same_domain(entries, first.domain)}
    end)
  end

  defp same_domain(entries, domain) do
    Enum.filter(entries, &(&1.domain == domain))
  end

  defp domain_label(domain) do
    domain
    |> Module.split()
    |> List.last()
  end

  # The actor cell: the tombstone renders as recorded, and a nil is
  # the honest system attribution (no actor rode the write).
  defp actor_copy(nil), do: gettext("System")
  defp actor_copy(label), do: label

  # The active-filter chip's copy: the :system assign is the filter
  # whose label is the literal System param.
  defp filter_copy(:system), do: gettext("System")
  defp filter_copy(label), do: label

  # The actor cell's filter link: a recorded label filters itself; the
  # nil tombstone's link is the literal "System" param (the system
  # filter).
  defp actor_link_filter(nil), do: "System"
  defp actor_link_filter(label), do: label

  # The changes cell: verbatim JSON in mono (the engine's fallback-map
  # grammar). REDACTED markers are values here and render as values —
  # that a sensitive attribute exists is the record, the value never
  # shipped.
  defp changes_json(version) do
    Jason.encode!(version.changes || %{}, pretty: true)
  end

  # The view controls' links — picker, filter clear, the malformed
  # source bounce — go through one query builder, so no control can
  # drop or mangle the filters. The pairs build ordered (resource
  # first), so the URLs read the same everywhere they render. The
  # picker and the drill links start a fresh view (the default table
  # state) — the existing posture.
  defp audit_path(key, actor, source, page) do
    [{"resource", Atom.to_string(key)}]
    |> put_param("actor", actor_param(actor))
    |> put_param("source", source)
    |> put_param("page", Integer.to_string(page))
    |> URI.encode_query()
    |> then(&"/admin/audit?#{&1}")
  end

  # The filter assign's URL spelling: a label rides itself, the system
  # filter is the literal "System" param, and no filter drops the
  # param.
  defp actor_param(:system), do: "System"
  defp actor_param(nil), do: nil
  defp actor_param(label), do: label

  # The surface's own filters, in a fixed order after the table's own
  # params; url_for/3 drops the absent ones.
  defp filters_extra(entry, filters) do
    [
      {"resource", Atom.to_string(entry.key)},
      {"actor", actor_param(filters.actor)},
      {"source", filters.source}
    ]
  end

  # The row cells' drill-down links: the engine's two-pair deep-link
  # shape (resource plus one filter), the exact grammar the record
  # History action builds. No page and no other filter rides along —
  # a drill starts that view fresh.
  defp drill_path(key, pairs) do
    [{"resource", Atom.to_string(key)} | pairs]
    |> URI.encode_query()
    |> then(&"/admin/audit?#{&1}")
  end

  defp put_param(params, _name, nil), do: params
  defp put_param(params, name, value), do: params ++ [{name, value}]

  # The column declarations, built per render so the labels ride the
  # live locale. Tracks and floors are the shared component's data:
  # every flexible column declares its floor, so the computed
  # min-width cannot strand it (the #608 review's finding, owned once
  # in the component).
  defp columns do
    [
      %{
        key: :when,
        label: gettext("When"),
        track: "minmax(11rem,1.2fr)",
        sort: :version_inserted_at,
        floor_rem: 11
      },
      %{key: :type, label: gettext("Type"), track: "5.5rem", sort: :version_action_type},
      %{
        key: :action,
        label: gettext("Action"),
        track: "minmax(8rem,1.4fr)",
        sort: :version_action_name,
        floor_rem: 8
      },
      %{key: :record, label: gettext("Record"), track: "7rem"},
      %{
        key: :actor,
        label: gettext("Actor"),
        track: "minmax(7rem,1fr)",
        sort: :actor_label,
        floor_rem: 7
      },
      %{
        key: :changes,
        label: gettext("Changes"),
        track: "minmax(12rem,1.6fr)",
        floor_rem: 12,
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
      <div class="appgram console contents" data-testid="admin-audit">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5" data-testid="admin-audit-title">
                {gettext("Audit trail")}
              </h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Every recorded change on the business resources, newest first. Each row names the actor, the action, and what moved. Destroyed records keep their history."
                )}
              </p>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="audit" pending_requests={@pending_storage_requests} />

            <div class="min-w-0 flex-1 space-y-6">
              <%!-- The resource selector: one disclosure over the whole
              browsable set, grouped by domain. Picking a resource
              starts a fresh view (filters belong to the view they
              were built in, a source filter from another resource
              could only read as an empty list). --%>
              <details
                class="group rounded-panel border border-line bg-panel"
                data-testid="admin-audit-picker"
              >
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm outline-offset-2 outline-focus focus-visible:outline-2 [&::-webkit-details-marker]:hidden">
                  <span class="flex items-baseline gap-2">
                    <span class="text-ink-muted">{gettext("Resource")}</span>
                    <span class="font-medium text-ink">{@entry.label}</span>
                  </span>
                  <.icon
                    name="hero-chevron-right"
                    class="size-3 text-ink-subtle transition-transform group-open:rotate-90"
                  />
                </summary>
                <div class="border-t border-line px-4 py-3">
                  <div :for={{domain_label, domain_entries} <- @groups} class="mb-3 last:mb-0">
                    <p class="font-mono text-xs font-medium uppercase tracking-[0.18em] text-ink-subtle">
                      {domain_label}
                    </p>
                    <div class="mt-1 flex flex-col items-start gap-0.5">
                      <.link
                        :for={pick <- domain_entries}
                        navigate={audit_path(pick.key, nil, nil, 1)}
                        data-testid={"admin-audit-pick-#{pick.key}"}
                        class={[
                          "rounded-control px-2 py-0.5 text-sm transition-colors",
                          pick.key == @entry.key && "font-medium text-ink",
                          pick.key != @entry.key &&
                            "text-ink-muted hover:bg-panel-raised hover:text-ink"
                        ]}
                      >
                        {pick.label}
                      </.link>
                    </div>
                  </div>
                </div>
              </details>

              <%!-- The active filters, as chips with one clear link.
              The source chip reads the engine's short-id idiom — the
              full id stays in the URL where deep links carry it. --%>
              <div
                :if={@filtered?}
                class="flex flex-wrap items-center gap-2"
                data-testid="admin-audit-filters"
              >
                <span
                  :if={@actor}
                  data-testid="admin-audit-filter-actor"
                  class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 text-xs text-ink"
                >
                  {gettext("Actor")}: {filter_copy(@actor)}
                </span>
                <span
                  :if={@source}
                  data-testid="admin-audit-filter-source"
                  class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 font-mono text-xs text-ink"
                >
                  {gettext("Record")}: {AdminResource.short_uuid(@source)}
                </span>
                <.link
                  navigate={audit_path(@entry.key, nil, nil, 1)}
                  data-testid="admin-audit-filter-clear"
                  class="text-xs font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Clear filters")}
                </.link>
              </div>

              <div :if={@rows_empty? and @filtered?} data-testid="admin-audit-filter-empty">
                <.empty_state title={gettext("Nothing matches these filters.")}>
                  {gettext(
                    "The filters name one actor or one record. Clear them to see the full history."
                  )}
                  <span class="mt-3 block">
                    <.link
                      navigate={audit_path(@entry.key, nil, nil, 1)}
                      data-testid="admin-audit-filter-empty-clear"
                      class="text-sm font-medium text-link underline-offset-2 hover:underline"
                    >
                      {gettext("Clear filters")}
                    </.link>
                  </span>
                </.empty_state>
              </div>

              <div :if={@rows_empty? and not @filtered?} data-testid="admin-audit-empty">
                <.empty_state title={gettext("No history yet.")}>
                  {gettext("Changes to this resource appear here the moment they are written.")}
                </.empty_state>
              </div>

              <%!-- The data table (#501): the shared component owns the
              chrome, the computed floor, the sort headers, the honest
              count, and the pager; this surface keeps its panel
              wrapper, its row grammar (the changes details under its
              own row), and its policy-scoped read. The row testid
              wraps the first cell's content: the component owns the
              row element itself. --%>
              <div
                :if={not @rows_empty?}
                class="rounded-panel border border-line bg-panel text-ink"
              >
                <AdminDataTable.data_table
                  id="admin-audit"
                  items={@streams.versions}
                  columns={@columns}
                  meta={table_meta(@table)}
                >
                  <:cell :let={version} col={:when}>
                    <span class="block" data-testid={"admin-audit-row-#{version.id}"}>
                      <span
                        class="whitespace-nowrap text-xs text-ink-muted"
                        title={DateTime.to_string(version.version_inserted_at)}
                        data-testid={"admin-audit-stamp-#{version.id}"}
                      >
                        {Calendar.strftime(version.version_inserted_at, "%b %d, %Y %H:%M UTC")}
                      </span>
                    </span>
                  </:cell>

                  <:cell :let={version} col={:type}>
                    <span data-testid={"admin-audit-type-#{version.id}"}>
                      <.badge class="px-1.5! text-[11px]!">
                        {AdminResource.label(version.version_action_type)}
                      </.badge>
                    </span>
                  </:cell>

                  <:cell :let={version} col={:action}>
                    <span
                      class="text-sm text-ink"
                      data-testid={"admin-audit-action-#{version.id}"}
                    >
                      {AdminResource.label(version.version_action_name)}
                    </span>
                  </:cell>

                  <:cell :let={version} col={:record}>
                    <span
                      class="font-mono text-xs"
                      data-testid={"admin-audit-record-#{version.id}"}
                    >
                      <%!-- Every generated version row carries the
                      source id — creates, updates, and destroys
                      alike (the reference is gone on destroy, the
                      id is not), so the cell always names its
                      record and links it. --%>
                      <.link
                        navigate={
                          drill_path(@entry.key, [
                            {"source", version.version_source_id}
                          ])
                        }
                        class="text-link underline-offset-2 hover:underline"
                        title={version.version_source_id}
                      >
                        {AdminResource.short_uuid(version.version_source_id)}
                      </.link>
                    </span>
                  </:cell>

                  <:cell :let={version} col={:actor}>
                    <span
                      class="text-sm text-ink"
                      data-testid={"admin-audit-actor-#{version.id}"}
                    >
                      <.link
                        navigate={
                          drill_path(@entry.key, [
                            {"actor", actor_link_filter(version.actor_label)}
                          ])
                        }
                        class="text-link underline-offset-2 hover:underline"
                      >
                        {actor_copy(version.actor_label)}
                      </.link>
                    </span>
                  </:cell>

                  <:cell :let={version} col={:changes}>
                    <details class="group" data-testid={"admin-audit-changes-#{version.id}"}>
                      <summary class="cursor-pointer list-none text-sm font-medium text-link underline-offset-2 outline-offset-2 outline-focus hover:underline focus-visible:outline-2 [&::-webkit-details-marker]:hidden">
                        {gettext("Changes")}
                      </summary>
                      <pre
                        class="mt-2 overflow-x-auto rounded-control bg-panel-raised p-3 font-mono text-xs whitespace-pre-wrap text-ink"
                        data-testid={"admin-audit-changes-json-#{version.id}"}
                      >{changes_json(version)}</pre>
                    </details>
                  </:cell>
                </AdminDataTable.data_table>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
