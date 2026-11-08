defmodule FluxValeWeb.AdminLive.Resources do
  @moduledoc """
  The generic resource console (#595, slice 1: the engine read path
  proven on Ops). Four read mounts over the exposure registry
  (`FluxValeWeb.AdminConsole` — the security boundary): the domain
  picker, the domain page, the paginated index, and the record show
  page. The write mounts (new/edit/destroy) are slice 2.

  Every read runs with the operator as actor (the AdminChrome assign)
  and repo-default authorization ON — the deliberate contrast with
  AshAdmin's effective `authorize?: false` (ADR-0027 Am. 1). No
  `authorize?: false` anywhere on this surface. Reads ride the primary
  read action with offset pagination (25 to a page, count-aware) and
  newest-first order where the resource carries `created_at`.

  Unknown domain/resource URL segments can never exist: they resolve
  against the registry's atoms and bounce to the landing with an honest
  flash (the size-edit idiom — the surface's existing unknown-page
  posture). An unknown record id is data, not a route — it flashes and
  bounces to the index the same way.

  Rendering is actor-safe by construction: the show page lists
  exactly the PUBLIC attributes in declaration order, and the index
  renders curated columns drawn only from public attributes plus the
  resource's DECLARED framework timestamps (created_at, pinned for
  row-age scanning) — audit metadata, never business attributes, the
  deliberate contrast with AshAdmin's render-everything posture
  (ADR-0027 Am. 1).
  """

  use FluxValeWeb, :live_view

  alias Ash.Resource.Info
  alias FluxValeWeb.AdminConsole
  alias FluxValeWeb.AdminResource
  alias FluxValeWeb.AdminShell

  @page_size 25

  # Auto columns: the label-ish attribute plus up to this many public
  # attrs, with created_at pinned last (the plan's columns contract).
  @auto_column_cap 4

  # The row-label heuristic's order (the plan): first match wins, else
  # the short id.
  @label_attr_order [:name, :title, :email, :key, :slug]

  @impl Phoenix.LiveView
  # The arms key on live_action, never params alone: LiveView merges
  # query params into mount params (the Topup :org posture), so
  # /admin/resources?domain=nope must stay the landing, not mount the
  # domain arm under a crafted query string.
  def mount(_params, _session, %{assigns: %{live_action: :domains}} = socket) do
    # D3's landing picker: the one Resources entry's target. Live
    # domains only; the honest one-liner names the pending set instead
    # of faking cards for it.
    domains =
      Enum.map(AdminConsole.domains(), fn domain ->
        %{key: domain.key, label: domain.label, count: length(domain.resources)}
      end)

    {:ok, assign(socket, domains: domains)}
  end

  def mount(%{"domain" => segment}, _session, %{assigns: %{live_action: :domain}} = socket) do
    case Enum.find(AdminConsole.domains(), &(Atom.to_string(&1.key) == segment)) do
      nil -> bounce_unknown(socket)
      domain -> {:ok, assign(socket, domain: domain_cards(domain))}
    end
  end

  def mount(
        %{"domain" => domain_segment, "resource" => resource_segment} = params,
        _session,
        %{assigns: %{live_action: :index}} = socket
      ) do
    case AdminConsole.fetch(domain_segment, resource_segment) do
      {:ok, entry} -> mount_index(entry, params, socket)
      :error -> bounce_unknown(socket)
    end
  end

  def mount(
        %{"domain" => domain_segment, "resource" => resource_segment, "id" => id},
        _session,
        %{assigns: %{live_action: :show}} = socket
      ) do
    case AdminConsole.fetch(domain_segment, resource_segment) do
      {:ok, entry} -> mount_show(entry, id, socket)
      :error -> bounce_unknown(socket)
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
      wide
    >
      <%!-- The console lane (#593 via #596): `wide` chrome + `appgram
      console` opts the page out of the centered measure — the sidebar
      anchors at the viewport gutter, the tables stretch. --%>
      <div class="appgram console contents" data-testid="admin-resources">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5" data-testid="admin-resources-title">
                {page_title(assigns)}
              </h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">{page_intro(assigns)}</p>
              <div :if={@live_action != :domains} class="mt-4">
                <.link
                  navigate={parent_path(assigns)}
                  data-testid="admin-resources-back"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {parent_copy(assigns)}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <%!-- The section sidebar (Am. 4, the #568 idiom); the domain,
        index, and record pages are sub-routes of the one Resources
        entry, so they mark the entry as an ancestor (location) and the
        landing marks it as the page. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="resources" exact={@live_action == :domains} />

            <div class="min-w-0 flex-1 space-y-6">
              <%= case @live_action do %>
                <%!-- D3's domain picker: one card per live domain. --%>
                <% :domains -> %>
                  <div
                    class="grid items-start gap-4 sm:grid-cols-2"
                    data-testid="admin-resources-domains"
                  >
                    <.link
                      :for={domain <- @domains}
                      navigate={~p"/admin/resources/#{domain.key}"}
                      data-testid={"admin-resources-domain-#{domain.key}"}
                      class="block rounded-panel border border-line-strong bg-panel p-5 shadow-sm transition-colors hover:bg-panel-raised"
                    >
                      <p class="text-base font-medium text-ink">{domain.label}</p>
                      <p class="mt-1 text-sm text-ink-muted">
                        {ngettext("1 resource", "%{count} resources", domain.count)}
                      </p>
                    </.link>
                  </div>
                  <p class="text-sm text-ink-subtle" data-testid="admin-resources-pending">
                    {gettext(
                      "Not every domain is on this console yet. The ones here are fully supported."
                    )}
                  </p>
                <% :domain -> %>
                  <div
                    class="grid items-start gap-4 sm:grid-cols-2"
                    data-testid="admin-resources-domain"
                  >
                    <.link
                      :for={resource <- @domain.resources}
                      navigate={~p"/admin/resources/#{@domain.key}/#{resource.key}"}
                      data-testid={"admin-resources-resource-#{resource.key}"}
                      class="block rounded-panel border border-line-strong bg-panel p-5 shadow-sm transition-colors hover:bg-panel-raised"
                    >
                      <p class="text-base font-medium text-ink">{resource.label}</p>
                      <p :if={resource.note} class="mt-1 text-sm text-ink-muted">{resource.note}</p>
                    </.link>
                  </div>
                <% :index -> %>
                  <div class="space-y-4" data-testid="admin-resource-index">
                    <.callout :if={@note} tone="info" data-testid="admin-resource-note">
                      {@note}
                    </.callout>

                    <div class="flex flex-wrap items-center justify-between gap-3">
                      <p class="text-sm text-ink-muted" data-testid="admin-resource-count">
                        {ngettext("1 row", "%{count} rows", @count)}
                      </p>
                      <AdminResource.pagination
                        current={@page_number}
                        total={@total_pages}
                        path={@index_path}
                      />
                    </div>

                    <div :if={@rows_empty?} data-testid="admin-resource-empty">
                      <.empty_state title={gettext("No rows yet.")}>
                        {gettext("This table is empty. Rows appear here as they are created.")}
                      </.empty_state>
                    </div>

                    <div
                      :if={not @rows_empty?}
                      class="overflow-x-auto rounded-panel border border-line bg-panel text-ink"
                    >
                      <%!-- The console's table grammar (the .table
                      component's exact chrome, hand-rolled because the
                      generic engine needs per-shape cell control). The
                      floor is measured like the people surface's: the
                      widest registry row (the flags table — key 10rem,
                      enabled 5rem, rollout 6rem, description 13rem,
                      created 7rem, view 4rem ≈ 45rem tracks + padding)
                      needs 46rem before columns start crowding; below
                      it the table rides its own overflow-x-auto, never
                      the page. --%>
                      <table
                        class="w-full min-w-[46rem] text-sm"
                        data-testid="admin-resource-table"
                      >
                        <thead>
                          <tr class="border-b border-line text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
                            <th
                              :for={col <- @columns}
                              class="px-4 py-3 font-medium"
                              data-testid={"admin-resource-col-#{col.name}"}
                            >
                              {col.label}
                            </th>
                            <th>
                              <span class="sr-only">{gettext("Actions")}</span>
                            </th>
                          </tr>
                        </thead>
                        <tbody id="admin-resource-rows" phx-update="stream">
                          <tr
                            :for={{dom_id, record} <- @streams.records}
                            id={dom_id}
                            class="border-b border-line last:border-0 transition-colors hover:bg-panel-raised/60"
                          >
                            <td
                              :for={col <- @columns}
                              class="px-4 py-3"
                              data-testid={"admin-resource-cell-#{col.name}-#{record.id}"}
                            >
                              <AdminResource.value
                                shape={col.shape}
                                value={Map.get(record, col.name)}
                              />
                            </td>
                            <td class="w-0 px-4 py-3 font-semibold">
                              <div class="flex gap-4">
                                <.link
                                  navigate={
                                    ~p"/admin/resources/#{@domain_key}/#{@resource_key}/#{record.id}"
                                  }
                                  data-testid={"admin-resource-view-#{record.id}"}
                                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                                >
                                  {gettext("View")}
                                </.link>
                              </div>
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </div>
                <% :show -> %>
                  <div
                    class="rounded-panel border border-line-strong bg-panel p-5 shadow-sm"
                    data-testid="admin-resource-show"
                  >
                    <dl class="divide-y divide-line">
                      <div
                        :for={field <- @fields}
                        class="grid gap-1 py-3 first:pt-0 sm:grid-cols-[10rem_1fr] sm:gap-4"
                        data-testid={"admin-resource-field-#{field.name}"}
                      >
                        <dt class="text-sm font-medium text-ink-muted">{field.label}</dt>
                        <dd class="min-w-0">
                          <AdminResource.value
                            shape={field.shape}
                            value={Map.get(@record, field.name)}
                            variant={:show}
                            id={"admin-resource-copy-#{field.name}"}
                          />
                        </dd>
                      </div>
                    </dl>
                  </div>
              <% end %>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # -- mounts -------------------------------------------------------------

  defp mount_index(entry, params, socket) do
    admin = socket.assigns.current_user
    page_number = parse_page(params["page"])
    page = read_page(entry.module, page_number, admin)
    count = page.count || 0
    total_pages = AdminResource.total_pages(count, @page_size)

    if page_number > total_pages and count > 0 do
      # A page past the end bounces to the real last page (the People
      # :home bounce idiom) — an honest URL, not a misleadingly empty
      # table.
      {:ok, push_navigate(socket, to: "#{index_path(entry)}?page=#{total_pages}")}
    else
      socket =
        socket
        |> assign(
          domain_key: entry.domain.key,
          domain_label: entry.domain.label,
          resource_key: entry.key,
          resource_label: resource_label(entry),
          note: entry.config[:note],
          columns: columns(entry),
          count: count,
          page_number: page_number,
          total_pages: total_pages,
          rows_empty?: page.results == [],
          index_path: index_path(entry)
        )
        |> stream(:records, page.results, reset: true)

      {:ok, socket}
    end
  end

  defp mount_show(entry, id, socket) do
    case Ash.get(entry.module, id, actor: socket.assigns.current_user) do
      {:ok, record} ->
        {:ok,
         assign(socket,
           domain_key: entry.domain.key,
           domain_label: entry.domain.label,
           resource_key: entry.key,
           resource_label: resource_label(entry),
           record: record,
           record_label: record_label(record, label_attr(entry)),
           fields: fields(entry.module),
           index_path: index_path(entry)
         )}

      {:error, _unknown_or_refused} ->
        # An unknown id and a policy denial read the same: this record
        # is not available from here (the size-edit posture).
        {:ok,
         socket
         |> put_flash(:error, gettext("That record is not available here."))
         |> push_navigate(to: index_path(entry))}
    end
  end

  # -- reads ---------------------------------------------------------------

  defp read_page(module, page_number, actor) do
    offset = (page_number - 1) * @page_size

    module
    |> Ash.Query.for_read(primary_read(module), %{}, actor: actor)
    |> sort_newest_first(module)
    |> Ash.read!(page: [limit: @page_size, offset: offset, count: true])
  end

  defp primary_read(module) do
    Info.primary_action(module, :read).name
  end

  # Newest first where the resource declares a created_at timestamp.
  # The guard keeps the engine total for a future resource without one.
  defp sort_newest_first(query, module) do
    if declared_timestamp(module, :created_at) do
      Ash.Query.sort(query, created_at: :desc)
    else
      # coveralls-ignore-start - every registry resource declares
      # created_at (the intake sanity passes verify it); no reachable
      # resource exercises this arm.
      query
      # coveralls-ignore-stop
    end
  end

  # -- introspection ---------------------------------------------------------

  # The ONLY non-public values this surface ever renders: the framework
  # timestamps, sourced exclusively from the resource's
  # create_timestamp/update_timestamp declarations (the plan's amended
  # parity criterion 2) — audit metadata, never business attributes.
  # Ash 3.37 has no Info.timestamps/1, so the source is Ash's own
  # discriminator for exactly those declarations (the same predicate
  # that wires Ecto autogenerate).
  defp declared_timestamps(module) do
    attrs = Info.attributes(module)
    Enum.filter(attrs, &Ash.Schema.timestamp_attribute?/1)
  end

  defp declared_timestamp(module, name) do
    declared = declared_timestamps(module)
    Enum.find(declared, &(&1.name == name))
  end

  # Everything a column may be built from: public attributes plus the
  # declared timestamps. Configured column names resolve against this
  # set and nothing else — an unknown name is skipped, never guessed.
  defp column_sources(module) do
    public = Info.public_attributes(module)
    stamps = declared_timestamps(module)
    public_pairs = Enum.map(public, &{&1.name, &1})
    timestamp_pairs = Enum.map(stamps, &{&1.name, &1})
    Map.new(public_pairs ++ timestamp_pairs)
  end

  # Index columns: the registry's curated list when set, else the auto
  # shape — the label-ish attribute first, then the next public attrs
  # up to the cap, created_at (the DECLARED timestamp) pinned last.
  # The pinned stamp is engine metadata the plan's columns contract
  # pins deliberately — row-age scanning on every table — while the
  # show page stays the public-attributes contract.
  @doc """
  The index's columns for a registry entry. Public seam: the intake
  tests drive configured-column resolution through it without a live
  registry entry carrying config.
  """
  @spec columns(map()) :: [map()]
  def columns(entry) do
    case entry.config[:columns] do
      nil -> auto_columns(entry)
      names -> configured_columns(entry, names)
    end
  end

  @doc """
  The names of the resource's declared framework timestamps — the only
  non-public values this surface ever renders (the plan's amended
  parity criterion 2). Public seam: the actor-safety tests assert the
  index's column ceiling against the same source the engine reads.
  """
  @spec declared_timestamp_names(module()) :: [String.t()]
  def declared_timestamp_names(module) do
    declared = declared_timestamps(module)
    Enum.map(declared, &Atom.to_string(&1.name))
  end

  defp auto_columns(entry) do
    attrs = Info.public_attributes(entry.module)
    label_name = label_attr(entry)

    label = column(find_attribute(entry.module, label_name))

    rest =
      attrs
      |> Enum.reject(&(&1.name in [:id, label_name]))
      |> Enum.take(@auto_column_cap - 1)
      |> Enum.map(&column/1)

    pinned = created_at_column(entry)

    [label] ++ rest ++ pinned
  end

  # The curated list honors names only — slices 4-5 trim wide resources
  # this way. An inert name (a renamed attribute, a typo) falls back by
  # being skipped: the row renders without it, never crashes, never
  # renders a non-public attribute it cannot resolve.
  defp configured_columns(entry, names) do
    sources = column_sources(entry.module)
    resolver = fn name -> resolve_column(sources, name) end
    Enum.flat_map(names, resolver)
  end

  defp resolve_column(sources, name) do
    case Map.fetch(sources, name) do
      {:ok, attr} -> [column(attr)]
      :error -> []
    end
  end

  defp column(attr) do
    %{
      name: attr.name,
      label: AdminResource.label(attr.name),
      shape: AdminResource.shape(attr)
    }
  end

  defp created_at_column(entry) do
    stamp = declared_timestamp(entry.module, :created_at)

    if stamp do
      [column(stamp)]
    else
      # coveralls-ignore-start - same arm as sort_newest_first: no
      # reachable registry resource lacks a created_at declaration.
      []
      # coveralls-ignore-stop
    end
  end

  defp find_attribute(module, name) do
    attrs = Info.attributes(module)
    Enum.find(attrs, &(&1.name == name))
  end

  defp label_attr(entry) do
    override = entry.config[:label_attr]
    label_attr(entry, override)
  end

  # nil before the atom clause — nil is an atom in Elixir, and the
  # override's absence is the heuristic's cue.
  defp label_attr(entry, nil) do
    attrs = Info.public_attributes(entry.module)
    names = MapSet.new(attrs, & &1.name)

    Enum.find(@label_attr_order, &MapSet.member?(names, &1)) || :id
  end

  # The override honors public attributes only — a label is a value the
  # operator reads, so a non-public (or stale) name falls back to the
  # heuristic instead of exposing anything.
  defp label_attr(entry, name) when is_atom(name) do
    public = Info.public_attributes(entry.module)

    if Enum.any?(public, &(&1.name == name)) do
      name
    else
      label_attr(entry, nil)
    end
  end

  # The show page: every public attribute in declaration order. This
  # list IS the actor-safety contract — nothing else renders.
  defp fields(module) do
    module
    |> Info.public_attributes()
    |> Enum.map(&column/1)
  end

  # -- small helpers ----------------------------------------------------------

  defp resource_label(entry) do
    entry.config[:label] || AdminResource.label(entry.key)
  end

  defp record_label(record, label_name) do
    case Map.get(record, label_name) do
      nil -> AdminResource.short_uuid(record.id)
      value -> to_string(value)
    end
  end

  defp domain_cards(domain) do
    resources =
      Enum.map(domain.resources, fn resource ->
        config = resource.config

        %{
          key: resource.key,
          label: config[:label] || AdminResource.label(resource.key),
          note: config[:note]
        }
      end)

    %{key: domain.key, label: domain.label, resources: resources}
  end

  defp index_path(entry), do: ~p"/admin/resources/#{entry.domain.key}/#{entry.key}"

  # ?page=N — anything but a positive integer reads as page one, and a
  # parsed integer is capped before the offset math: a crafted 19-digit
  # page must not reach arithmetic as a bignum.
  @page_bound 10_000

  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {number, ""} when number >= 1 -> min(number, @page_bound)
      _not_a_positive_integer -> 1
    end
  end

  defp parse_page(_not_a_string), do: 1

  # The honest-unknown posture the other admin surfaces use (the
  # size-edit idiom): URL segments that can never exist flash and
  # bounce to the registry's real pages. A raise here would fight the
  # LiveView lifecycle (the initial render has no conn to 404 through).
  defp bounce_unknown(socket) do
    {:ok,
     socket
     |> put_flash(:error, gettext("That page does not exist here."))
     |> push_navigate(to: ~p"/admin/resources")}
  end

  # -- band copy -----------------------------------------------------------

  defp page_title(%{live_action: :domains}), do: gettext("Resource console")
  defp page_title(%{live_action: :domain, domain: domain}), do: domain.label
  defp page_title(%{live_action: :index, resource_label: label}), do: label
  defp page_title(%{live_action: :show, record_label: label}), do: label

  defp page_intro(%{live_action: :domains}) do
    gettext(
      "Every domain the console exposes, with its resources and every public field. The raw tables behind the curated sections."
    )
  end

  defp page_intro(%{live_action: :domain}) do
    gettext(
      "The resources this domain exposes. Reads run through the resource policies with your account as the actor."
    )
  end

  defp page_intro(%{live_action: :index}) do
    gettext(
      "Every row, newest first, 25 to a page. Reads run through the resource policies with your account as the actor."
    )
  end

  defp page_intro(%{live_action: :show}) do
    gettext(
      "Every public attribute of this record. Non-public attributes never render on this surface."
    )
  end

  defp parent_path(%{live_action: :domain}), do: ~p"/admin/resources"
  defp parent_path(%{live_action: :index, domain_key: key}), do: ~p"/admin/resources/#{key}"
  defp parent_path(%{live_action: :show, index_path: path}), do: path

  defp parent_copy(%{live_action: :domain}), do: gettext("Back to the domains")

  defp parent_copy(%{live_action: :index, domain_label: label}),
    do: gettext("Back to %{name}", name: label)

  defp parent_copy(%{live_action: :show, resource_label: label}),
    do: gettext("Back to %{name}", name: label)
end
