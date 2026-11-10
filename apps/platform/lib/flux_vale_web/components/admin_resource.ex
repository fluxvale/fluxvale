defmodule FluxValeWeb.AdminResource do
  @moduledoc """
  The generic resource console's type-driven render pieces (#595, the
  plan at docs/plans/595-resource-console.md): one value renderer per
  attribute shape (the plan's rendering table), the count-aware offset
  pagination controls, the write affordances (the visible?-gated New
  link and actions bar — nothing renders when nothing is permitted),
  and the form-input mapping (attribute shape to `<.input>` type, the
  plan's input contracts table). The LiveView engine
  (`FluxValeWeb.AdminLive.Resources`) introspects the resource and
  hands each attribute's shape and value here — nothing in this module
  reads a resource, so the registry stays the only surface that knows
  modules.

  Shapes land slice by slice as their resources do (slice 1: Ops).
  Anything unrecognized renders through the fallback — the value's
  `inspect/1` in mono — so an introspected attribute is never a crash,
  just an honest look at the raw value.

  Copy line: authored literals ride gettext; strings derived from
  schema identifiers (column labels, enum values) render as derived —
  no locale story exists for schema names and static extraction can't
  see them. UUIDs and timestamps set the precedent: values are values.
  """

  use FluxValeWeb, :html

  # -- shape mapping -----------------------------------------------------

  @doc """
  An Ash attribute's render shape: the type module (expanded — `:ci_string`
  arrives as `Ash.Type.CiString`) plus the constraints decide. Unknown
  types answer `:unknown` and ride the fallback renderer.
  """
  @spec shape(map()) ::
          :uuid | :string | :integer | :decimal | :boolean | :datetime | :enum | :unknown
  def shape(%{type: Ash.Type.UUIDv7}), do: :uuid
  def shape(%{type: Ash.Type.UUID}), do: :uuid
  def shape(%{type: Ash.Type.String}), do: :string
  # ci_string renders as plain text, its original case — no case games.
  def shape(%{type: Ash.Type.CiString}), do: :string
  def shape(%{type: Ash.Type.Integer}), do: :integer
  # Decimal is its own shape, right mono like the integer — the engine
  # renders the raw value and NOTHING else (no currency inference, no
  # precision games; the curated billing components own money grammar).
  def shape(%{type: Ash.Type.Decimal}), do: :decimal
  def shape(%{type: Ash.Type.Boolean}), do: :boolean
  # Ash spells them UtcDatetime/UtcDatetimeUsec (any precision → one shape).
  def shape(%{type: Ash.Type.UtcDatetime}), do: :datetime
  def shape(%{type: Ash.Type.UtcDatetimeUsec}), do: :datetime

  def shape(%{type: Ash.Type.Atom, constraints: constraints}) do
    if Keyword.has_key?(constraints, :one_of), do: :enum, else: :unknown
  end

  # A custom enum (`use Ash.Type.Enum`) declares its values through the
  # macro's values/0 — EntryType, EntryReason, and their siblings render
  # as badges exactly like a one_of atom. Composite types export
  # nothing of the sort and fall through to the honest inspect.
  def shape(%{type: type}) when is_atom(type) do
    if enum_type?(type), do: :enum, else: :unknown
  end

  def shape(_unrecognized), do: :unknown

  defp enum_type?(type), do: function_exported?(type, :values, 0)

  # -- value rendering ---------------------------------------------------

  @doc """
  One typed value. `variant` picks the table-cell treatment (compact,
  truncated, `title` carrying the full value) or the show-page
  treatment (the full value, copyable where copying is the point).
  `nil` renders as an honest Not set in either variant.
  """

  attr(:shape, :atom,
    required: true,
    values: [:uuid, :string, :integer, :decimal, :boolean, :datetime, :enum, :unknown]
  )

  attr(:value, :any, required: true)
  attr(:variant, :atom, default: :index, values: [:index, :show])

  attr(:id, :string,
    default: nil,
    doc: "unique DOM id for the show variant's copy affordance (defaults to a static one)"
  )

  @spec value(map()) :: Phoenix.LiveView.Rendered.t()
  def value(%{value: nil} = assigns), do: empty(assigns)

  def value(%{shape: :uuid, variant: :index} = assigns) do
    ~H"""
    <span class="block truncate font-mono text-xs text-ink-muted" title={@value}>
      {short_uuid(@value)}
    </span>
    """
  end

  def value(%{shape: :uuid, variant: :show} = assigns) do
    ~H"""
    <span class="flex flex-wrap items-center gap-2">
      <span class="font-mono text-sm break-all text-ink" data-testid="admin-resource-uuid">
        {@value}
      </span>
      <.copy_button id={@id || "admin-resource-copy"} value={@value} />
    </span>
    """
  end

  def value(%{shape: :string} = assigns) do
    assigns = assign(assigns, text: to_string(assigns.value))

    ~H"""
    <%= if @variant == :index do %>
      <span class="block max-w-48 truncate text-sm text-ink" title={@text}>{@text}</span>
    <% else %>
      <span class="text-sm break-words text-ink">{@text}</span>
    <% end %>
    """
  end

  def value(%{shape: :integer, variant: :index} = assigns) do
    ~H"""
    <span class="flex justify-end font-mono text-sm text-ink" title={@value}>{@value}</span>
    """
  end

  def value(%{shape: :integer, variant: :show} = assigns) do
    ~H"""
    <span class="font-mono text-sm text-ink">{@value}</span>
    """
  end

  # Decimal rides the integer's treatments with the raw value verbatim
  # — to_string, no formatting (the no-currency-inference rule).
  def value(%{shape: :decimal, variant: :index} = assigns) do
    assigns = assign(assigns, text: Decimal.to_string(assigns.value))

    ~H"""
    <span class="flex justify-end font-mono text-sm text-ink" title={@text}>{@text}</span>
    """
  end

  def value(%{shape: :decimal, variant: :show} = assigns) do
    assigns = assign(assigns, text: Decimal.to_string(assigns.value))

    ~H"""
    <span class="font-mono text-sm text-ink">{@text}</span>
    """
  end

  def value(%{shape: :boolean} = assigns) do
    assigns = assign(assigns, label: if(assigns.value, do: gettext("Yes"), else: gettext("No")))

    ~H"""
    <span class="text-sm text-ink">{@label}</span>
    """
  end

  def value(%{shape: :datetime, variant: :index} = assigns) do
    ~H"""
    <span
      class="whitespace-nowrap text-xs text-ink-muted"
      title={DateTime.to_string(@value)}
      data-testid="admin-resource-datetime"
    >
      {Calendar.strftime(@value, "%b %d, %Y")}
    </span>
    """
  end

  def value(%{shape: :datetime, variant: :show} = assigns) do
    ~H"""
    <span
      class="whitespace-nowrap text-sm text-ink"
      title={DateTime.to_string(@value)}
      data-testid="admin-resource-datetime"
    >
      {Calendar.strftime(@value, "%b %d, %Y %H:%M UTC")}
    </span>
    """
  end

  def value(%{shape: :enum} = assigns) do
    ~H"""
    <span data-testid="admin-resource-enum">
      <.badge class="px-1.5! text-[11px]!">{humanize(@value)}</.badge>
    </span>
    """
  end

  # The fallback every later shape leans on until its clause lands:
  # the raw value, inspected, mono — honest rather than pretty.
  def value(%{variant: :index} = assigns) do
    assigns = assign(assigns, text: inspect(assigns.value))

    ~H"""
    <span class="block max-w-48 truncate font-mono text-xs text-ink-muted" title={@text}>
      {@text}
    </span>
    """
  end

  def value(assigns) do
    assigns = assign(assigns, text: inspect(assigns.value))

    ~H"""
    <pre
      class="overflow-x-auto font-mono text-xs whitespace-pre-wrap text-ink"
      data-testid="admin-resource-unknown"
    >{@text}</pre>
    """
  end

  defp empty(assigns) do
    ~H"""
    <span class="text-sm text-ink-subtle" data-testid="admin-resource-empty-value">
      {gettext("Not set")}
    </span>
    """
  end

  @doc """
  A belongs_to cell whose destination is a registry resource: the
  loaded record's label, linked to its show page.
  """

  attr(:label, :string, required: true)
  attr(:path, :string, required: true)
  attr(:record_id, :string, required: true)

  @spec link_value(map()) :: Phoenix.LiveView.Rendered.t()
  def link_value(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class="text-sm text-link underline-offset-2 hover:underline"
      data-testid={"admin-resource-fk-#{@record_id}"}
    >
      {@label}
    </.link>
    """
  end

  # -- pagination --------------------------------------------------------

  @doc """
  Pages in a count-aware run: 1..total, never below one (an empty
  table is page one, not page zero).
  """
  @spec total_pages(integer(), pos_integer()) :: pos_integer()
  def total_pages(count, limit), do: max(ceil(count / limit), 1)

  @doc """
  The page-number window: current always visible with a page each
  side, first and last always visible, `:gap` marking an elided run.
  At beta scale every page fits — the window only starts eliding past
  seven pages. The window stays three wide at the edges (a current at
  the very end shows total-2..total), and pages adjacent to an
  endpoint join it without a gap.
  """
  @spec page_window(pos_integer(), pos_integer()) :: [pos_integer() | :gap]
  def page_window(_current, total) when total <= 7, do: Enum.to_list(1..total)

  def page_window(current, total) do
    # Three wide, clamped: at either end the window pads toward the
    # inside instead of shrinking.
    first =
      if current + 1 >= total, do: max(total - 2, 1), else: max(current - 1, 1)

    last =
      if current - 1 <= 1, do: min(3, total), else: min(current + 1, total)

    window = Enum.to_list(first..last)

    head =
      case first do
        1 -> []
        2 -> [1]
        _interior -> [1, :gap]
      end

    tail =
      cond do
        last == total -> []
        last == total - 1 -> [total]
        true -> [:gap, total]
      end

    head ++ window ++ tail
  end

  @doc """
  Prev/next plus the page-number window, as links to `path?page=N`.
  Renders nothing at one page — a lone number is not a control.
  """

  attr(:current, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:path, :string, required: true, doc: "the index path without its query string")

  @spec pagination(map()) :: Phoenix.LiveView.Rendered.t()
  def pagination(assigns) do
    ~H"""
    <nav
      :if={@total > 1}
      class="flex flex-wrap items-center gap-1.5"
      aria-label={gettext("Pagination")}
      data-testid="admin-resource-pagination"
    >
      <.page_link
        path={@path}
        number={@current - 1}
        disabled={@current == 1}
        label={gettext("Previous")}
        testid="admin-resource-prev"
      />
      <%= for entry <- page_window(@current, @total) do %>
        <%= if entry == :gap do %>
          <span class="px-1 text-sm text-ink-subtle" aria-hidden="true">…</span>
        <% else %>
          <.link
            navigate={"#{@path}?page=#{entry}"}
            aria-current={entry == @current && "page"}
            class={[
              "rounded-control px-2 py-1 text-sm transition-colors",
              entry == @current && "font-medium text-ink",
              entry != @current && "text-ink-muted hover:bg-panel-raised hover:text-ink"
            ]}
            data-testid={"admin-resource-page-#{entry}"}
          >
            {entry}
          </.link>
        <% end %>
      <% end %>
      <.page_link
        path={@path}
        number={@current + 1}
        disabled={@current == @total}
        label={gettext("Next")}
        testid="admin-resource-next"
      />
    </nav>
    """
  end

  attr(:path, :string, required: true)
  attr(:number, :integer, required: true)
  attr(:disabled, :boolean, required: true)
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
      navigate={"#{@path}?page=#{@number}"}
      class="rounded-control px-2 py-1 text-sm text-ink-muted transition-colors hover:bg-panel-raised hover:text-ink"
      data-testid={@testid}
    >
      {@label}
    </.link>
    """
  end

  # -- labels ------------------------------------------------------------

  @doc """
  Column and field labels from attribute names: snake_case to
  capitalized words, with `ID` kept as the initialism operators read.
  Derived, not authored copy — see the moduledoc's copy line.
  """
  @spec label(atom() | String.t()) :: String.t()
  def label(:id), do: "ID"

  def label(name) when is_atom(name) do
    text = Atom.to_string(name)
    label(text)
  end

  def label(name) when is_binary(name) do
    spaced = String.replace(name, "_", " ")
    String.capitalize(spaced)
  end

  # Enum values render humanized in a neutral badge (the plan's
  # rendering table) — derived like the column labels above.
  defp humanize(value) when is_atom(value) do
    text = Atom.to_string(value)
    humanize(text)
  end

  defp humanize(value) when is_binary(value) do
    spaced = String.replace(value, "_", " ")
    String.capitalize(spaced)
  end

  @doc """
  The first eight characters of a uuid — the console's short-id idiom
  (index cells, label fallbacks).
  """
  @spec short_uuid(String.t()) :: String.t()
  def short_uuid(value), do: String.slice(value, 0, 8)

  # -- form inputs (the write path) ---------------------------------------

  @doc """
  The `<.input>` type for an attribute shape (the plan's input
  mapping): string/ci_string and uuid FKs → text, integer → number,
  decimal → number (stepped, see input_step/1), boolean → checkbox,
  a one_of atom or a custom `Ash.Type.Enum` → select, utc datetimes
  (either precision) → datetime-local.

  `nil` is a shape the engine still cannot map (array-of-array, an
  array whose inner maps to a non-textarea input): the form SKIPS the
  field rather than guess at an encoding, the flagged-not-forced rule.
  Maps, arrays of scalars, and module composites answer "textarea" —
  they cast from JSON-shaped plain maps and their own validation rides
  AshPhoenix's field errors (slice 4's JSON-textarea contract).
  """
  @spec input_type(map()) :: String.t() | nil
  def input_type(%{type: Ash.Type.String}), do: "text"
  def input_type(%{type: Ash.Type.CiString}), do: "text"
  # FK labels come from the relationship (slice 4); the input is text —
  # a uuid is typed, never picked from a list the engine cannot size.
  def input_type(%{type: Ash.Type.UUID}), do: "text"
  def input_type(%{type: Ash.Type.Integer}), do: "number"
  def input_type(%{type: Ash.Type.Decimal}), do: "number"
  def input_type(%{type: Ash.Type.Boolean}), do: "checkbox"

  # Datetime inputs (the plan's table has no row — TaxRate's
  # effective_from is the first): datetime-local submits ISO8601 which
  # the UtcDatetime cast accepts directly.
  def input_type(%{type: Ash.Type.UtcDatetime}), do: "datetime-local"
  def input_type(%{type: Ash.Type.UtcDatetimeUsec}), do: "datetime-local"

  # JSON textareas (slice 4's contract): the map shape casts from
  # JSON-shaped plain maps (probe-verified), the type's own validation
  # rides AshPhoenix's field errors.
  def input_type(%{type: Ash.Type.Map}), do: "textarea"

  def input_type(%{type: Ash.Type.Atom, constraints: constraints}) do
    if Keyword.has_key?(constraints, :one_of), do: "select", else: nil
  end

  # A custom enum type selects like a one_of atom (the same source the
  # renderer's shape/1 reads — values/0 from `use Ash.Type.Enum`).
  # Every other atom type is a module composite: they cast from
  # JSON-shaped plain maps (probe-verified), so they textarea like the
  # map shape above.
  def input_type(%{type: type}) when is_atom(type) do
    if(enum_type?(type), do: "select", else: "textarea")
  end

  # Arrays of scalars and of composites textarea through the same
  # JSON-shaped casting. Array-of-array stays unmappable (nil) —
  # nothing uses it, and the guard must precede the recursion: the
  # generic clause would otherwise re-enter the {:array,
  # Ash.Type.String} clause and map it, which the unit tests pin nil.
  def input_type(%{type: {:array, Ash.Type.String}}), do: "textarea"
  def input_type(%{type: {:array, {:array, _inner}}}), do: nil

  def input_type(%{type: {:array, inner}}) do
    case input_type(%{type: inner}) do
      "textarea" -> "textarea"
      _composite_unmappable -> nil
    end
  end

  def input_type(_unmapped), do: nil

  @doc """
  A select's options: a one_of constraint's declared atoms, or a custom
  enum's `values/0` (EntryType and siblings) — string values either way
  (the cast resolves them back through the type, no atom is ever built
  from input), labels derived like column labels.
  """
  @spec enum_options(map()) :: [{String.t(), String.t()}]
  def enum_options(%{constraints: constraints} = field) do
    one_of = enum_values(constraints, field)
    Enum.map(one_of, fn value -> {label(value), Atom.to_string(value)} end)
  end

  # The one_of constraint wins when present; a custom enum type
  # (values/0 from `use Ash.Type.Enum`) is the other source. Both are
  # guaranteed to exist wherever this runs — input_type answers
  # "select" only for the two enum shapes, and both attribute and
  # argument fields always carry a constraints list (Ash defaults it
  # to []).
  defp enum_values(constraints, %{type: type}) when is_list(constraints) do
    case Keyword.fetch(constraints, :one_of) do
      {:ok, one_of} -> one_of
      :error -> type.values()
    end
  end

  @doc """
  An input's required flag: `allow_nil?` governs, except checkboxes —
  a boolean's false is a real value the hidden input always submits,
  so a required checkbox would force every boolean on.
  """
  @spec input_required?(map(), String.t()) :: boolean()
  def input_required?(_attr, "checkbox"), do: false
  def input_required?(attr, _submits_a_value), do: not attr.allow_nil?

  @doc """
  An input's step for the number type: decimals submit fractions (the
  plan's contracts table pins step 0.01 — without it the browser's
  default step of 1 rejects a fractional cpu_cores at submit time);
  everything else answers nil (no step attribute renders).
  """
  @spec input_step(map()) :: String.t() | nil
  def input_step(%{type: Ash.Type.Decimal}), do: "0.01"
  def input_step(_whole_numbers), do: nil

  # -- write affordances ---------------------------------------------------

  @doc """
  The index's create affordance: a link to the :new route. `path: nil`
  (no create action the actor may run) renders nothing — the actions
  surface shows nothing when nothing is permitted.
  """

  attr(:path, :string, default: nil, doc: "the :new route, or nil to render nothing")

  @spec new_button(map()) :: Phoenix.LiveView.Rendered.t()
  # The empty clause needs the sigil's assigns binding to render a
  # valid (empty) template — a bare list is not renderable.
  def new_button(%{path: nil} = assigns), do: ~H""

  def new_button(assigns) do
    ~H"""
    <.link
      navigate={@path}
      data-testid="admin-resource-new"
      class="rounded-control border border-line bg-panel px-3 py-1.5 text-sm font-medium text-link transition-colors hover:bg-panel-raised"
    >
      {gettext("New")}
    </.link>
    """
  end

  @doc """
  The record page's actions bar: one Edit link per permitted update
  action, one Delete button per permitted destroy action (the delete
  opens the confirm_block; it never destroys directly), and — for a
  business-set resource — the record's audit History deep link. Both
  action lists empty AND no history renders nothing — the bar is
  absent, not an empty box.
  """

  attr(:update_actions, :list,
    required: true,
    doc: "[%{name: action_name, path: path, label: label}] — one per permitted update action"
  )

  attr(:destroy_actions, :list,
    required: true,
    doc: "[%{name: action_name, label: label}] — one per permitted destroy action"
  )

  attr(:history, :string,
    default: nil,
    doc: "the record's audit History link path, nil outside the business set"
  )

  @spec actions_bar(map()) :: Phoenix.LiveView.Rendered.t()
  # Same empty-template nothing as new_button's empty clause.
  def actions_bar(%{update_actions: [], destroy_actions: [], history: nil} = assigns),
    do: ~H""

  def actions_bar(assigns) do
    ~H"""
    <div
      class="flex flex-wrap items-center gap-3 border-t border-line pt-4"
      data-testid="admin-resource-actions"
    >
      <.link
        :if={@history}
        navigate={@history}
        data-testid="admin-resource-history"
        class="text-sm font-medium text-link underline-offset-2 hover:underline"
      >
        {gettext("History")}
      </.link>
      <.link
        :for={action <- @update_actions}
        navigate={action.path}
        data-testid={"admin-resource-edit-#{action.name}"}
        class="text-sm font-medium text-link underline-offset-2 hover:underline"
      >
        {action.label}
      </.link>

      <button
        :for={action <- @destroy_actions}
        type="button"
        phx-click="open-destroy"
        phx-value-action={action.name}
        phx-disable-with={gettext("Opening...")}
        data-testid={"admin-resource-destroy-#{action.name}"}
        class="text-sm font-medium text-danger underline-offset-2 hover:underline"
      >
        {action.label}
      </button>
    </div>
    """
  end
end
