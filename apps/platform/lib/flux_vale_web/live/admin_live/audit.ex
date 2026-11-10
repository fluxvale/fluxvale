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
  direct admin-only read policy (D7) decides, never the UI. Primary
  read, newest first on the version's own stamp
  (`version_inserted_at`), 25 to a page with count (the engine's
  pagination grammar).

  Filters ride query params: `?resource=<key>` picks the resource
  (unknown segments bounce to the default honestly, the registry's
  posture), `?actor=<label>` exact-matches the denormalized actor
  tombstone (no joins — the label rides the row), and
  `?source=<uuid>` narrows one record's history (the engine show
  pages' History deep link). A source that is not UUID-shaped bounces
  with an honest flash — garbage never reaches the query.

  The rows render the tombstone as recorded: a nil `actor_label` is
  the honest system attribution and says so, REDACTED markers in
  `changes` render verbatim (that a sensitive attribute exists is the
  record — the value never shipped), and a destroy keeps its row (no
  source reference, D6). Unknown anything bounces; nothing is guessed.
  """

  use FluxValeWeb, :live_view

  alias Ash.Resource.Info
  alias FluxValeWeb.AdminAudit
  alias FluxValeWeb.AdminResource
  alias FluxValeWeb.AdminShell

  # The filters' expressions parse through Ash.Expr (the gateways
  # search's non-keyword call form) — the require is load-bearing.
  require Ash.Query

  @page_size 25
  @page_bound 10_000

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    entries = AdminAudit.entries()

    case pick_entry(entries, params["resource"]) do
      {:ok, entry} ->
        case source_filter(params["source"]) do
          {:ok, source} ->
            filters = %{actor: actor_filter(params["actor"]), source: source}
            mount_index(entries, entry, filters, params, socket)

          :error ->
            # A non-UUID ?source= is a malformed deep link: garbage
            # never reaches the query, and the bounce keeps the
            # resource context (the honest-unknown posture).
            {:ok,
             socket
             |> put_flash(:error, gettext("That history link is malformed."))
             |> push_navigate(to: audit_path(entry.key, nil, nil, 1))}
        end

      :error ->
        # A ?resource= segment that resolves against no entry can
        # never exist: bounce to the default with the console's honest
        # flash (the registry's unknown-segment posture).
        {:ok,
         socket
         |> put_flash(:error, gettext("That page does not exist here."))
         |> push_navigate(to: ~p"/admin/audit")}
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
                  {gettext("Actor")}: {@actor}
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

              <div class="flex flex-wrap items-center justify-between gap-3">
                <p class="text-sm text-ink-muted" data-testid="admin-audit-count">
                  {ngettext("1 change", "%{count} changes", @count)}
                </p>
                <.audit_pagination
                  current={@page_number}
                  total={@total_pages}
                  entry={@entry}
                  actor={@actor}
                  source={@source}
                />
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

              <div
                :if={not @rows_empty?}
                class="overflow-x-auto rounded-panel border border-line bg-panel text-ink"
              >
                <%!-- The engine's table chrome (the console's exact
                grammar). The changes cell is the widest track: the
                details opens into a mono pre under its own row. --%>
                <table class="w-full min-w-[52rem] text-sm" data-testid="admin-audit-table">
                  <thead>
                    <tr class="border-b border-line text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
                      <th class="px-4 py-3 font-medium">{gettext("When")}</th>
                      <th class="px-4 py-3 font-medium">{gettext("Type")}</th>
                      <th class="px-4 py-3 font-medium">{gettext("Action")}</th>
                      <th class="px-4 py-3 font-medium">{gettext("Actor")}</th>
                      <th>
                        <span class="sr-only">{gettext("Changes")}</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody id="admin-audit-rows" phx-update="stream">
                    <tr
                      :for={{dom_id, version} <- @streams.versions}
                      id={dom_id}
                      data-testid={"admin-audit-row-#{version.id}"}
                      class="border-b border-line last:border-0 transition-colors hover:bg-panel-raised/60"
                    >
                      <td
                        class="whitespace-nowrap px-4 py-3 text-xs text-ink-muted"
                        title={DateTime.to_string(version.version_inserted_at)}
                        data-testid={"admin-audit-stamp-#{version.id}"}
                      >
                        {Calendar.strftime(version.version_inserted_at, "%b %d, %Y %H:%M UTC")}
                      </td>
                      <td class="px-4 py-3" data-testid={"admin-audit-type-#{version.id}"}>
                        <.badge class="px-1.5! text-[11px]!">
                          {AdminResource.label(version.version_action_type)}
                        </.badge>
                      </td>
                      <td
                        class="px-4 py-3 text-sm text-ink"
                        data-testid={"admin-audit-action-#{version.id}"}
                      >
                        {AdminResource.label(version.version_action_name)}
                      </td>
                      <td
                        class="px-4 py-3 text-sm text-ink"
                        data-testid={"admin-audit-actor-#{version.id}"}
                      >
                        {actor_copy(version.actor_label)}
                      </td>
                      <td class="px-4 py-3">
                        <details
                          class="group"
                          data-testid={"admin-audit-changes-#{version.id}"}
                        >
                          <summary class="cursor-pointer list-none text-sm font-medium text-link underline-offset-2 outline-offset-2 outline-focus hover:underline focus-visible:outline-2 [&::-webkit-details-marker]:hidden">
                            {gettext("Changes")}
                          </summary>
                          <pre
                            class="mt-2 overflow-x-auto rounded-control bg-panel-raised p-3 font-mono text-xs whitespace-pre-wrap text-ink"
                            data-testid={"admin-audit-changes-json-#{version.id}"}
                          >{changes_json(version)}</pre>
                        </details>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # -- mounts ---------------------------------------------------------------

  defp mount_index(entries, entry, filters, params, socket) do
    admin = socket.assigns.current_user
    page_number = parse_page(params["page"])
    page = read_page(entry, filters, page_number, admin)

    # count: true rides the page opts, so the paginator always sets it
    # (the Offset struct's own type says integer, not nil).
    count = page.count
    total_pages = AdminResource.total_pages(count, @page_size)

    if page_number > total_pages and count > 0 do
      # A page past the end bounces to the real last page (the
      # engine's honest-URL posture) — filters ride along.
      {:ok,
       push_navigate(socket,
         to: audit_path(entry.key, filters.actor, filters.source, total_pages)
       )}
    else
      socket =
        socket
        |> assign(
          entries: entries,
          groups: groups(entries),
          entry: entry,
          actor: filters.actor,
          source: filters.source,
          filtered?: filters.actor != nil or filters.source != nil,
          count: count,
          page_number: page_number,
          total_pages: total_pages,
          rows_empty?: page.results == []
        )
        |> stream(:versions, page.results, reset: true)

      {:ok, socket}
    end
  end

  # -- reads ----------------------------------------------------------------

  @doc """
  The section's version page for one entry: the Version module read
  through its domain with the actor riding the query and authorization
  ON (repo default), primary read, newest first on the version's own
  stamp, 25 to a page with count. Public seam: the version-read policy
  pin drives this exact path with a member actor — the Forbidden there
  is the mixin's answer through the section's own query, not a crafted
  side read.
  """
  @spec read_page(
          map(),
          %{actor: String.t() | nil, source: String.t() | nil},
          pos_integer(),
          term()
        ) ::
          Ash.Page.Offset.t()
  def read_page(entry, filters, page_number, actor) do
    module = AdminAudit.version_module(entry)
    offset = (page_number - 1) * @page_size

    module
    |> Ash.Query.for_read(primary_read(module), %{}, actor: actor)
    |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
    |> apply_filters(filters)
    |> Ash.read!(page: [limit: @page_size, offset: offset, count: true])
  end

  defp primary_read(module) do
    Info.primary_action(module, :read).name
  end

  # The tombstone makes the actor filter a column match — no joins.
  # The value compares exactly as recorded.
  defp apply_filters(query, %{actor: actor, source: source}) do
    query
    |> apply_actor_filter(actor)
    |> apply_source_filter(source)
  end

  defp apply_actor_filter(query, nil), do: query
  defp apply_actor_filter(query, label), do: Ash.Query.filter(query, actor_label == ^label)

  defp apply_source_filter(query, nil), do: query

  defp apply_source_filter(query, source),
    do: Ash.Query.filter(query, version_source_id == ^source)

  # -- param hygiene ----------------------------------------------------------

  # The default resource is the list's first entry — the picker's own
  # order decides what a bare /admin/audit shows.
  defp pick_entry(entries, nil), do: {:ok, List.first(entries)}
  defp pick_entry(_entries, segment), do: AdminAudit.fetch(segment)

  defp actor_filter(nil), do: nil

  defp actor_filter(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> nil
      label -> label
    end
  end

  # A crafted non-binary ?actor= (the page[]= shape) filters nothing:
  # the view renders the honest full history rather than guessing at
  # an encoding.
  defp actor_filter(_not_a_string), do: nil

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

  # ?page=N — the engine's grammar verbatim: anything but a positive
  # integer reads as page one, and a parsed integer is capped before
  # the offset math.
  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {number, ""} when number >= 1 -> min(number, @page_bound)
      _not_a_positive_integer -> 1
    end
  end

  defp parse_page(_not_a_string), do: 1

  # -- render helpers ---------------------------------------------------------

  # The picker's groups: the entries already carry display order, so a
  # chunk on the domain plus the domain's own short name is the whole
  # grouping.
  defp groups(entries) do
    entries
    |> Enum.chunk_by(& &1.domain)
    |> Enum.map(fn group -> {domain_label(hd(group).domain), group} end)
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

  # The changes cell: verbatim JSON in mono (the engine's fallback-map
  # grammar). REDACTED markers are values here and render as values —
  # that a sensitive attribute exists is the record, the value never
  # shipped.
  defp changes_json(version) do
    Jason.encode!(version.changes || %{}, pretty: true)
  end

  # Every link this surface builds — picker, filters, pagination —
  # goes through one query builder, so no control can drop or mangle
  # the filters. The pairs build ordered (resource first), so the
  # URLs read the same everywhere they render.
  defp audit_path(key, actor, source, page) do
    [{"resource", Atom.to_string(key)}]
    |> put_param("actor", actor)
    |> put_param("source", source)
    |> put_param("page", Integer.to_string(page))
    |> URI.encode_query()
    |> then(&"/admin/audit?#{&1}")
  end

  defp put_param(params, _name, nil), do: params
  defp put_param(params, name, value), do: params ++ [{name, value}]

  # -- pagination (the engine's window, audit's links) -------------------------

  attr(:current, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:entry, :map, required: true)
  attr(:actor, :string, default: nil)
  attr(:source, :string, default: nil)

  defp audit_pagination(assigns) do
    ~H"""
    <nav
      :if={@total > 1}
      class="flex flex-wrap items-center gap-1.5"
      aria-label={gettext("Pagination")}
      data-testid="admin-audit-pagination"
    >
      <.page_link
        path={audit_path(@entry.key, @actor, @source, @current - 1)}
        disabled={@current == 1}
        label={gettext("Previous")}
        testid="admin-audit-prev"
      />
      <%= for number <- AdminResource.page_window(@current, @total) do %>
        <%= if number == :gap do %>
          <span class="px-1 text-sm text-ink-subtle" aria-hidden="true">…</span>
        <% else %>
          <.page_link
            path={audit_path(@entry.key, @actor, @source, number)}
            active={number == @current}
            label={Integer.to_string(number)}
            testid={"admin-audit-page-#{number}"}
          />
        <% end %>
      <% end %>
      <.page_link
        path={audit_path(@entry.key, @actor, @source, @current + 1)}
        disabled={@current == @total}
        label={gettext("Next")}
        testid="admin-audit-next"
      />
    </nav>
    """
  end

  attr(:path, :string, required: true)
  attr(:disabled, :boolean, default: false)
  attr(:active, :boolean, default: false)
  attr(:label, :string, required: true)
  attr(:testid, :string, required: true)

  defp page_link(%{disabled: true} = assigns) do
    ~H"""
    <span class="rounded-control px-2 py-1 text-sm text-ink-subtle" aria-disabled="true">
      {@label}
    </span>
    """
  end

  defp page_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      aria-current={@active && "page"}
      class={[
        "rounded-control px-2 py-1 text-sm transition-colors",
        @active && "font-medium text-ink",
        not @active && "text-ink-muted hover:bg-panel-raised hover:text-ink"
      ]}
      data-testid={@testid}
    >
      {@label}
    </.link>
    """
  end
end
