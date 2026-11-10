defmodule FluxValeWeb.Components.AdminDataTable do
  @moduledoc """
  The admin data table (#501, the owner directive): ONE server-driven
  table — sortable columns, search state, real pagination — shared by
  every admin list surface. Explicitly NOT the DataTables.js vendor
  library: no new JS dependency, every state change is a server round
  trip that re-queries through the surface's own read.

  The contract is PRESENTATION only. The component renders the chrome
  (header, rows, pagination, the announced state) and the adopting
  surface owns the query, the events, and the policy scoping — a
  search never widens a read. Sort, page, page size, and the search
  term ride query params, so a URL states the table's view and
  reloading lands on it. Garbage params fall back to defaults
  (`parse_params/2`), never crash.

  Columns are per-surface declarations: a label, the grid track (one
  literal string per column, assembled into an inline style so the
  template and the floor math read the same list), an optional
  `floor_rem` for flexible columns, an optional `sort` field (the
  surface whitelists its own — never a raw param into a query sort),
  `align`, and `sr_only` for action columns. The min-width floor is
  computed from the fixed tracks plus the declared flexible floors,
  so the forgotten-floor class of bug (the #608 review's finding)
  cannot recur, and the chrome always rides its own overflow-x-auto
  below the floor (the md-band posture: internal scroll, never the
  page).

  The cells ride slots, so each surface keeps its own row grammar
  (badges, action columns, confirm and detail rows under a row)
  inside the shared chrome. The table is native LiveView: streams in,
  streams out, no client JS.
  """

  use FluxValeWeb, :html

  @default_size 25
  @sizes [25, 50, 100]
  # The search term cap: a crafted megabyte q param is a URL, not a
  # query plan. Longer terms fall back honestly to the cap.
  @query_cap 200
  # The chrome's own geometry: gap-x-3 between columns, px-3 padding.
  @gap_rem 0.75
  @chrome_padding_rem 1.5
  # A page param far past the end is clamped by the surface's read;
  # this bound only keeps a crafted offset from being a full scan.
  @max_page 10_000

  # -- the shared grid chrome (#606), now the DataTable's internals --

  @doc """
  The admin grid tables' header class (#602/#606): the one chrome the
  hand-rolled tables shared byte-for-byte, now owned here so the
  adopting surfaces cannot drift from it. The `grid-cols-[...]`
  tracks left the class layer for an inline style when the component
  took over the track math — the template is assembled from the same
  column declarations the floor reads, so Tailwind's source scan no
  longer gates them.
  """
  @spec header_row_class() :: String.t()
  def header_row_class do
    "grid items-center gap-x-3 border-b border-line px-3 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase"
  end

  @doc """
  The body-row counterpart of `header_row_class/0`. Rows carry no
  separator here: the component draws the separators on the stream
  item wrappers.
  """
  @spec body_row_class() :: String.t()
  def body_row_class do
    "grid items-center gap-x-3 px-3 py-3 transition-colors hover:bg-panel-raised/60"
  end

  # -- view state: params in, state out, URL back out --------------------

  @doc """
  Parses the table's query params into view state. Every field falls
  back to its default on garbage: an unknown sort field or direction,
  a non-numeric page, a size outside the allowed set, a non-binary
  query. The crafted-shape class probes this contract; the answer is
  always a valid view, never a crash.

  Options: `:sortable` (the surface's whitelisted sort fields) and
  `:sizes` (defaults to #{@sizes}).
  """
  @spec parse_params(term(), keyword()) :: %{
          sort: {atom(), :asc | :desc} | nil,
          page: pos_integer(),
          size: pos_integer(),
          query: String.t(),
          after: String.t() | nil,
          before: String.t() | nil,
          total: non_neg_integer() | nil
        }
  def parse_params(params, opts \\ []) do
    sizes = Keyword.get(opts, :sizes, @sizes)
    sortable = Keyword.get(opts, :sortable, [])

    %{
      sort: parse_sort(params["sort"], params["dir"], sortable),
      page: parse_page(params["page"]),
      size: parse_size(params["size"], sizes),
      query: parse_query(params["q"]),
      after: parse_cursor(params["after"]),
      before: parse_cursor(params["before"]),
      # Filled by the surface's offset-mode read; nil keeps the state
      # keyset-shaped until then.
      total: nil
    }
  end

  # A sort param is honored only when the field is whitelisted and the
  # direction is known; anything else is the surface's default order.
  defp parse_sort(raw_field, raw_dir, sortable) when is_binary(raw_field) do
    field = valid_field(raw_field, sortable)
    dir = parse_dir(raw_dir)

    case field do
      nil -> nil
      known -> {known, dir}
    end
  end

  defp parse_sort(_raw_field, _raw_dir, _sortable), do: nil

  # The direction rides its field: a lone dir param is ignored.
  defp parse_dir(raw_dir)
  defp parse_dir("desc"), do: :desc
  defp parse_dir(_other), do: :asc

  defp valid_field(raw_field, sortable) when is_list(sortable) do
    Enum.find(sortable, fn field -> Atom.to_string(field) == raw_field end)
  end

  # A whole positive page, bounded: garbage falls back to page 1.
  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {page, ""} when page >= 1 and page <= @max_page -> page
      _not_a_page -> 1
    end
  end

  defp parse_page(_raw), do: 1

  @doc """
  The page size for a raw param, from the table's allowed set. A
  value outside the set falls back to the default (25).
  """
  @spec parse_size(term(), [pos_integer()]) :: pos_integer()
  def parse_size(raw, sizes \\ @sizes)

  def parse_size(raw, sizes) when is_binary(raw) do
    parsed =
      Enum.find(sizes, fn size -> Integer.to_string(size) == raw end)

    parsed || @default_size
  end

  def parse_size(_raw, _sizes), do: @default_size

  @doc """
  The page-size set: 25 (the default), 50, 100 — one set for every
  table.
  """
  @spec default_sizes() :: [pos_integer()]
  def default_sizes, do: @sizes

  defp parse_query(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.slice(0, @query_cap)
  end

  defp parse_query(_raw), do: ""

  @doc """
  The search term's honest cap, for the surfaces' own search
  handlers: trimmed and bounded to the same 200 characters
  parse_params applies, so an event-built term never rides a longer
  pattern than a param-built one.
  """
  @spec cap_query(term()) :: String.t()
  def cap_query(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.slice(0, @query_cap)
  end

  def cap_query(_raw), do: ""

  # Keyset cursors are opaque strings; only their presence matters.
  defp parse_cursor(raw) when is_binary(raw) and raw != "", do: raw
  defp parse_cursor(_raw), do: nil

  @doc """
  The canonical URL for a table view: the base path plus only the
  params that differ from the defaults, so the default view is the
  bare path and every other view states itself. A URL states the
  table's view; reloading lands on it. The params ride one fixed
  order, so a view's URL is byte-stable.
  """
  @spec url_for(String.t(), map()) :: String.t()
  def url_for(base, state) do
    case view_params(state) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  # One fixed param order: q, sort, dir, page, size, then the keyset
  # cursors. Absent-as-default params fall out of the URL entirely.
  defp view_params(state) do
    pairs = [
      query_pair(state),
      sort_pair(state[:sort]),
      dir_pair(state[:sort]),
      page_pair(state.page),
      size_pair(state.size),
      cursor_pair("after", state[:after]),
      cursor_pair("before", state[:before])
    ]

    Enum.reject(pairs, &is_nil/1)
  end

  defp query_pair(%{query: query}) when query != "", do: {"q", query}
  defp query_pair(_state), do: nil

  defp sort_pair({field, _dir}), do: {"sort", Atom.to_string(field)}
  defp sort_pair(nil), do: nil

  defp dir_pair({_field, dir}), do: {"dir", Atom.to_string(dir)}
  defp dir_pair(nil), do: nil

  defp page_pair(page) when page > 1, do: {"page", Integer.to_string(page)}
  defp page_pair(_page), do: nil

  defp size_pair(@default_size), do: nil

  defp size_pair(size) do
    {"size", Integer.to_string(size)}
  end

  defp cursor_pair(_name, nil), do: nil

  defp cursor_pair(name, cursor) do
    {name, cursor}
  end

  @doc """
  The "sort" event's answer: the field must be whitelisted (a crafted
  field leaves the current sort alone), clicking the sorted field
  flips its direction, clicking a new field sorts by it ascending.
  """
  @spec toggle_sort({atom(), :asc | :desc} | nil, term(), [atom()]) ::
          {atom(), :asc | :desc} | nil
  def toggle_sort(current, raw_field, sortable) when is_binary(raw_field) do
    case valid_field(raw_field, sortable) do
      nil ->
        current

      field ->
        case current do
          {^field, :asc} -> {field, :desc}
          {^field, :desc} -> {field, :asc}
          _other -> {field, :asc}
        end
    end
  end

  def toggle_sort(current, _raw_field, _sortable), do: current

  @doc """
  The offset mode's page math: an honest page count from the filtered
  total, and the shown window ("26 to 50 of 128"). Never fewer than
  one page, so an empty surface still reads as page 1.
  """
  @spec page_count(pos_integer(), pos_integer()) :: pos_integer()
  def page_count(total, size) when total > 0 do
    divided = total / size

    divided
    |> Float.ceil()
    |> trunc()
  end

  def page_count(_total, _size), do: 1

  @doc """
  The keyset page's navigation cursors, the ash_json_api link rules:
  a forward page always offers prev (we came from there) and offers
  next only when Ash says more?, a backward page mirrors it, and the
  first page offers neither until more? says otherwise.
  """
  @spec keyset_links(Ash.Page.Keyset.t()) :: %{
          next: String.t() | nil,
          prev: String.t() | nil
        }
  def keyset_links(%Ash.Page.Keyset{} = page) do
    %{next: next_cursor(page), prev: prev_cursor(page)}
  end

  def keyset_links(_other), do: %{next: nil, prev: nil}

  defp next_cursor(page) do
    last = cursor_at(page, :last)

    cond do
      forward_page?(page) and page.more? -> last
      backward_page?(page) -> last
      first_page?(page) and page.more? -> last
      true -> nil
    end
  end

  defp prev_cursor(page) do
    first = cursor_at(page, :first)

    cond do
      backward_page?(page) and page.more? -> first
      forward_page?(page) -> first
      true -> nil
    end
  end

  defp forward_page?(page), do: page.after != nil and page.before == nil

  defp backward_page?(page), do: page.before != nil and page.after == nil

  defp first_page?(page), do: page.after == nil and page.before == nil

  # Ash stamps every keyset result with its own cursor under the
  # query's sort (__metadata__.keyset) — the per-row cursor the links
  # are built from.
  defp cursor_at(%Ash.Page.Keyset{results: []}, _at), do: nil

  defp cursor_at(%Ash.Page.Keyset{results: results}, :last) do
    keyset_of(Enum.at(results, -1))
  end

  defp cursor_at(%Ash.Page.Keyset{results: results}, :first) do
    keyset_of(List.first(results))
  end

  defp keyset_of(%{__metadata__: %{keyset: keyset}}) when is_binary(keyset), do: keyset

  # Ash stamps every keyset result with its cursor; a result without
  # one cannot be produced through a real read (the metadata write
  # rides the same query that returned the row), so this arm is
  # defensive totality over the shape.
  # coveralls-ignore-next-line - unreachable through a real keyset read
  defp keyset_of(_no_keyset), do: nil

  # -- the component ------------------------------------------------------

  # The attrs are the surface-side contract; the moduledoc owns the
  # narrative.
  attr(:id, :string,
    required: true,
    doc: "The stream container's DOM id. All data-testids derive from it."
  )

  attr(:items, :list, required: true, doc: "The LiveView stream, @streams.name.")

  attr(:columns, :list,
    required: true,
    doc:
      "Per-column declarations: key, label, track (a grid track string), :sort field or nil, :align (:left or :right), :sr_only, :floor_rem for flexible columns."
  )

  attr(:meta, :map,
    required: true,
    doc:
      "The view state: query, page, size, sort, total (offset mode) or showing plus next_cursor/prev_cursor (keyset mode), sizes, and the surface's event names."
  )

  attr(:row_class, :any,
    default: nil,
    doc: "fn item -> extra row class string or nil (a per-row tint, the billing countdown rows)."
  )

  slot :cell, required: true do
    attr(:col, :atom, required: true, doc: "Which column declaration this cell renders.")
  end

  slot(:expansion, doc: "Renders under a row (confirm panels, detail expansions).")

  @spec data_table(map()) :: Phoenix.LiveView.Rendered.t()
  def data_table(assigns) do
    # The page-size set rides the meta (a surface may narrow it); the
    # default is the module's one set. Resolved here because a module
    # attribute reads as an assign inside HEEx.
    assigns = assign(assigns, :page_sizes, Map.get(assigns.meta, :sizes, @sizes))

    ~H"""
    <div>
      <p
        class="sr-only"
        role="status"
        aria-live="polite"
        data-testid={"#{@id}-announcement"}
      >
        {announcement(@meta, @columns)}
      </p>

      <%!-- The chrome renders only with rows present: the empty
      grammar is the surface's own (the panel-inset empty), and a
      dangling header over an empty state promises columns nothing is
      there to fill. --%>
      <div class="overflow-x-auto" data-noscroll>
        <div
          role="table"
          class="w-full text-ink"
          style={floor_style(@columns)}
          data-testid={"#{@id}-table"}
        >
          <div
            role="row"
            class={header_row_class()}
            style={grid_style(@columns)}
            data-testid={"#{@id}-header"}
          >
            <div
              :for={col <- @columns}
              role="columnheader"
              aria-sort={aria_sort(col, @meta)}
              class={[
                "truncate",
                col[:align] == :right && "text-right",
                col[:sr_only] && "sr-only"
              ]}
              data-testid={"#{@id}-header-#{col[:key]}"}
            >
              <button
                :if={col[:sort]}
                type="button"
                phx-click={Map.get(@meta, :sort_event, "sort")}
                phx-value-field={to_string(col[:sort])}
                phx-disable-with={gettext("Working...")}
                class={sort_button_class(col, @meta)}
                data-testid={"#{@id}-sort-#{col[:sort]}"}
              >
                {col[:label]}
                <.icon name={sort_icon(col[:sort], @meta)} class="size-3" />
              </button>
              <span :if={col[:sort] == nil}>{col[:label]}</span>
            </div>
          </div>

          <div id={@id} phx-update="stream" role="rowgroup">
            <div :for={{dom_id, item} <- @items} id={dom_id} role="none">
              <div
                role="row"
                class={[body_row_class(), row_extra(@row_class, item)]}
                style={grid_style(@columns)}
              >
                <div :for={col <- @columns} role="cell" class={cell_class(col)}>
                  {render_slot(cell_for(@cell, col), item)}
                </div>
              </div>

              <%!-- render_slot answers nil for an unassigned slot;
              normalized here so the presence check stays a plain
              comparison. --%>
              <% detail = if @expansion == [], do: "", else: render_slot(@expansion, item) %>
              <div :if={detail != ""} role="row">
                <div role="cell">
                  {detail}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- The footer: the honest count, the page-size set, and
      prev/next with real disabled states. Offset mode names the page
      ("Page 2 of 6"); keyset mode has no totals and tells the truth
      about that instead. --%>
      <div
        class="mt-3 flex flex-wrap items-center justify-between gap-3"
        data-testid={"#{@id}-pagination"}
      >
        <p class="text-sm text-ink-muted" data-testid={"#{@id}-count"}>
          {count_copy(@meta)}
        </p>

        <div class="flex flex-wrap items-center gap-4">
          <span class="text-xs text-ink-muted">{gettext("Rows:")}</span>
          <div
            class="flex items-center gap-1"
            role="group"
            aria-label={gettext("Rows per page")}
            data-testid={"#{@id}-sizes"}
          >
            <button
              :for={size <- @page_sizes}
              type="button"
              aria-pressed={size_pressed?(size, @meta)}
              phx-click={Map.get(@meta, :size_event, "size")}
              phx-value-size={size}
              phx-disable-with={gettext("Working...")}
              class={size_button_class(size, @meta)}
              data-testid={"#{@id}-size-#{size}"}
            >
              {size}
            </button>
          </div>

          <div class="flex items-center gap-2">
            <button
              type="button"
              disabled={not has_prev?(@meta)}
              phx-click={Map.get(@meta, :page_event, "page")}
              phx-value-nav="prev"
              phx-disable-with={gettext("Working...")}
              class={page_button_class(@meta)}
              data-testid={"#{@id}-page-prev"}
            >
              {gettext("Prev")}
            </button>
            <span
              :if={offset_mode?(@meta)}
              class="text-sm tabular-nums text-ink-muted"
              data-testid={"#{@id}-page-label"}
            >
              {gettext("Page %{page} of %{count}",
                page: @meta.page,
                count: page_count(@meta.total, @meta.size)
              )}
            </span>
            <button
              type="button"
              disabled={not has_next?(@meta)}
              phx-click={Map.get(@meta, :page_event, "page")}
              phx-value-nav="next"
              phx-disable-with={gettext("Working...")}
              class={page_button_class(@meta)}
              data-testid={"#{@id}-page-next"}
            >
              {gettext("Next")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp cell_for(cells, col) do
    Enum.find(cells, fn slot -> slot.col == col[:key] end)
  end

  defp cell_class(col) do
    base = "min-w-0"

    case col[:align] do
      :right -> base <> " text-right"
      _left -> base
    end
  end

  defp row_extra(nil, _item), do: nil
  defp row_extra(fun, item) when is_function(fun, 1), do: fun.(item)

  # -- the track math (the pledged finding: one owner, once) -------------

  # The grid template, assembled from the column declarations: the same
  # list the floor math reads, so the template and the floor cannot
  # disagree. Inline style, not a class: the tracks are data now.
  @doc false
  @spec grid_style([map()]) :: String.t()
  def grid_style(columns) do
    tracks = Enum.map_join(columns, " ", & &1.track)

    "grid-template-columns: #{tracks}"
  end

  # The min-width floor: every column's own minimum (a fixed track's
  # rem, or the declared floor of a flexible one, whichever is larger),
  # plus the gaps, plus the chrome padding. A column list with no
  # declared floors still floors at its fixed tracks, so the collapse
  # below the floor that the #608 review caught cannot recur.
  @doc false
  @spec floor_style([map()]) :: String.t()
  def floor_style(columns) when columns != [] do
    column_min = Enum.reduce(columns, 0.0, &floor_add/2)
    gaps = @gap_rem * (length(columns) - 1)
    total = column_min + gaps + @chrome_padding_rem
    rounded = Float.round(total, 2)

    "min-width: #{:erlang.float_to_binary(rounded, decimals: 2)}rem"
  end

  defp floor_add(col, acc) do
    acc + max(col[:floor_rem] || 0.0, fixed_rem(col[:track]))
  end

  # A literal fixed track ("5.5rem") contributes itself; a flexible
  # track (minmax, fr, repeat) contributes nothing on its own.
  defp fixed_rem(track) when is_binary(track) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)rem$/, track) do
      [_full, raw] -> parse_rem(raw)
      _not_fixed -> 0.0
    end
  end

  defp parse_rem(raw) do
    {value, ""} = Float.parse(raw)
    value
  end

  # -- header state -------------------------------------------------------

  # aria-sort on every sortable columnheader: the sorted column names
  # its direction, the rest read "none". Unsortable columns carry no
  # aria-sort at all.
  defp aria_sort(col, meta) do
    case col[:sort] do
      nil ->
        nil

      field ->
        case meta[:sort] do
          {^field, :asc} -> "ascending"
          {^field, :desc} -> "descending"
          _unsorted -> "none"
        end
    end
  end

  defp sort_icon(field, meta) do
    case meta[:sort] do
      {^field, :asc} -> "hero-chevron-up"
      {^field, :desc} -> "hero-chevron-down"
      _unsorted -> "hero-chevron-up-down"
    end
  end

  defp sort_button_class(col, meta) do
    base =
      "inline-flex items-center gap-1 uppercase tracking-inherit outline-offset-2 outline-focus focus-visible:outline-2 hover:text-ink motion-safe:transition-colors motion-safe:duration-(--motion-fast)"

    sorted? =
      case meta[:sort] do
        {field, _dir} -> field == col[:sort]
        nil -> false
      end

    if sorted?, do: base <> " text-ink", else: base
  end

  # -- pagination ---------------------------------------------------------

  defp offset_mode?(meta), do: is_integer(meta[:total])

  defp has_prev?(meta) do
    if offset_mode?(meta), do: meta.page > 1, else: meta[:prev_cursor] != nil
  end

  defp has_next?(meta) do
    if offset_mode?(meta) do
      meta.page < page_count(meta.total, meta.size)
    else
      meta[:next_cursor] != nil
    end
  end

  # aria-pressed wants the literal strings: HEEx renders a boolean
  # true as an empty attribute, which the pressed state must not be.
  defp size_pressed?(size, meta) do
    if meta.size == size, do: "true", else: "false"
  end

  defp size_button_class(size, meta) do
    base =
      "rounded-full border px-2.5 py-0.5 text-xs font-medium motion-safe:transition-colors motion-safe:duration-(--motion-fast) outline-offset-2 outline-focus focus-visible:outline-2"

    active? = meta.size == size

    if active?,
      do: base <> " border-primary/25 bg-primary-muted text-link",
      else: base <> " border-line bg-panel text-ink-muted hover:text-ink"
  end

  defp page_button_class(_meta) do
    "rounded-control border border-line bg-panel px-2.5 py-1 text-sm font-medium text-ink hover:bg-panel-raised motion-safe:transition-colors motion-safe:duration-(--motion-fast) outline-offset-2 outline-focus focus-visible:outline-2 disabled:pointer-events-none disabled:opacity-50"
  end

  # The count copy. Offset mode derives the shown window from the
  # total (the last page may be short); keyset mode has no totals and
  # tells the truth about that — the surface reports how many rows
  # this page holds. The chrome renders only with rows present (the
  # surfaces gate it), and the contract is enforced here too: a zero
  # total reads the honest zero, never "Showing 1 to 25 of 0".
  defp count_copy(meta) do
    cond do
      # The rows-present gate keeps a populated table away from this
      # arm; it exists so a future caller cannot render "Showing 1 to
      # 25 of 0" — the honest zero is the fence.
      # coveralls-ignore-start - unreachable while the gate holds
      offset_mode?(meta) and meta.total == 0 ->
        gettext("No entries.")

      # coveralls-ignore-stop

      offset_mode?(meta) ->
        first = (meta.page - 1) * meta.size + 1
        last = min(meta.page * meta.size, meta.total)

        gettext("Showing %{first} to %{last} of %{total}.",
          first: first,
          last: last,
          total: meta.total
        )

      true ->
        gettext("Showing %{count} entries.", count: meta[:showing] || 0)
    end
  end

  # -- the announced state (#624's live-region grammar) -------------------

  defp announcement(meta, columns) do
    sort_line = sort_line(meta, columns)

    Enum.join([sort_line | page_and_search_lines(meta)], " ")
  end

  defp sort_line(meta, columns) do
    case meta[:sort] do
      nil ->
        gettext("Default order.")

      {field, dir} ->
        label = sort_label(columns, field)
        spoken = if dir == :asc, do: gettext("ascending"), else: gettext("descending")

        gettext("Sorted by %{label}, %{order}.", label: label, order: spoken)
    end
  end

  # The sort announcement uses the column's own label, so the operator
  # hears the words the header prints. A sort field with no declaring
  # column cannot be minted through the UI (the sort event only fires
  # from a header button whose column carries the field, and each
  # surface's whitelist mirrors its columns) — the fallback is
  # defensive totality over a surface-declaration bug.
  defp sort_label(columns, field) do
    col = Enum.find(columns, fn candidate -> candidate[:sort] == field end)

    case col do
      %{label: label} -> label
      # coveralls-ignore-next-line - unreachable while whitelist and columns agree
      _missing -> Atom.to_string(field)
    end
  end

  defp page_and_search_lines(meta) do
    page_line =
      if offset_mode?(meta) do
        gettext("Page %{page} of %{count}.",
          page: meta.page,
          count: page_count(meta.total, meta.size)
        )
      else
        ""
      end

    search_line =
      if meta[:query] != nil and meta.query != "" do
        gettext("Search: %{term}.", term: meta.query)
      else
        ""
      end

    [page_line, search_line]
  end
end
