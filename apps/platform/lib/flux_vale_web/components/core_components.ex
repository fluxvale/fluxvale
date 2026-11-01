defmodule FluxValeWeb.CoreComponents do
  @moduledoc """
  The FluxVale design system (#178): the core UI components on the
  amber token set (see `assets/css/app.css` — v1 heritage ramp).

  Hand-written Tailwind utilities on semantic tokens (`bg-primary`,
  `text-ink`, `border-line`, …) — no daisyUI classes here. The full set
  is showcased in the storybook (`FluxValeWeb.Storybook`, /storybook):
  every component there renders through this module, so the storybook
  is the living reference.

  Colors: `primary` (amber) for actions and emphasis; `ink`/`ink-muted`/
  `ink-subtle` for text; `canvas`/`panel`/`panel-raised` for surfaces;
  `success`/`warning`/`danger` for state. Both modes flip via
  `[data-theme=dark]`.

  Callers may pass `class` to any component: it is appended to (not
  replacing) the component's own classes.
  """

  use Phoenix.Component

  # Verified routes without the full :html use — html_helpers imports
  # CoreComponents (circular); this block only wires ~p.
  use FluxValeWeb, :verified_routes

  alias FluxValeWeb.InstanceStatus

  alias Phoenix.HTML.Form
  use Gettext, backend: FluxValeWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices as top-right toasts. The toast is display-only
  (#294): its boxes pass clicks through to the page beneath; the close
  button is the one clickable thing on it.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      class="pointer-events-none fixed top-4 right-4 z-50 w-[calc(100%-2rem)] max-w-sm"
      {@rest}
    >
      <%!-- #294: pointer-events on these boxes is load-bearing (display-only
           toast) — the dismiss handler rides the close button, the one
           element that opts back in; don't undo it via rest/class. --%>
      <div class={[
        "pointer-events-none flex items-start gap-3 rounded-panel border bg-panel p-4 [box-shadow:var(--elevation-lg)]",
        @kind == :info && "border-line text-ink",
        @kind == :error && "border-line-danger text-ink"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="mt-0.5 size-5 shrink-0 text-link"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="mt-0.5 size-5 shrink-0 text-danger"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="text-sm font-semibold">{@title}</p>
          <p class="text-sm text-ink-muted">{msg}</p>
        </div>
        <button
          type="button"
          class="group -m-1 cursor-pointer p-1 pointer-events-auto outline-offset-2 outline-focus focus-visible:outline-2"
          aria-label={gettext("close")}
          phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
        >
          <.icon name="hero-x-mark" class="size-4 text-ink-subtle group-hover:text-ink-muted" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button (or link, via `href`/`navigate`/`patch`) on the
  design system's button styles.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="secondary" size="sm">Cancel</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr(:rest, :global,
    include: ~w(href navigate patch method download name value disabled target rel)
  )

  attr(:class, :any, default: nil, doc: "appended to the variant/size classes")

  attr(:variant, :string,
    values: ~w(primary secondary ghost destructive),
    default: "primary",
    doc: "primary = amber action, secondary = bordered panel, ghost = text"
  )

  attr(:size, :string, values: ~w(sm md lg), default: "md")

  # #21: form-submit buttons need explicit type="submit" (default is "button"
  # per the HTML spec only when inside forms — be deliberate)
  attr(:type, :string, default: nil)
  slot(:inner_block, required: true)

  def button(assigns) do
    base =
      "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-control font-medium transition-[color,background-color,border-color,box-shadow,translate] duration-(--motion-fast) outline-offset-2 outline-focus focus-visible:outline-2 disabled:pointer-events-none"

    # Disabled reads inert, not faded-in-place: neutral surface + subtle
    # text (the vision QA flagged white-on-amber-wash as decorative).
    # Pair is ink-subtle on panel-raised: 5.51:1 light / 4.77:1 dark.
    disabled =
      "disabled:border disabled:border-line disabled:bg-panel-raised disabled:text-ink-subtle disabled:shadow-none"

    variants = %{
      "primary" =>
        "border border-line-primary bg-primary text-on-primary shadow-sm hover:bg-primary-hover hover:shadow-md active:bg-primary-active motion-safe:active:translate-y-px active:shadow-xs",
      "secondary" =>
        "border border-line-strong bg-panel text-ink shadow-sm hover:bg-panel-raised",
      "ghost" => "text-ink-muted hover:bg-panel-raised hover:text-ink",
      "destructive" => "border border-line-danger bg-panel text-danger hover:bg-danger-muted"
    }

    sizes = %{
      "sm" => "h-8 px-3 text-xs",
      "md" => "h-10 px-4 text-sm",
      "lg" => "h-12 px-6 text-base"
    }

    assigns =
      assign(assigns,
        class: [
          base,
          disabled,
          Map.fetch!(variants, assigns.variant),
          Map.fetch!(sizes, assigns.size),
          assigns[:class]
        ]
      )

    if assigns.rest[:href] || assigns.rest[:navigate] || assigns.rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button type={@type} class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr(:id, :any, default: nil)
  # default nil: stories/playground call without a form field — a bare
  # attr would KeyError on @name there (the field clause sets it for
  # form callers).
  attr(:name, :any, default: nil)
  attr(:label, :string, default: nil)
  attr(:value, :any, default: nil)

  attr(:type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)
  )

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"
  )

  attr(:errors, :list, default: [])
  attr(:checked, :boolean, doc: "the checked flag for checkbox inputs")
  attr(:prompt, :string, default: nil, doc: "the prompt for select inputs")
  attr(:options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2")
  attr(:multiple, :boolean, default: false, doc: "the multiple flag for select inputs")
  attr(:class, :any, default: nil, doc: "appended to the control's base classes")
  attr(:error_class, :any, default: nil, doc: "appended when the field has errors")

  attr(:rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)
  )

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    # explicit caller attrs win over the field's; the attr defaults
    # (nil) would otherwise shadow the field via assign_new
    name = assigns[:name] || if(assigns.multiple, do: field.name <> "[]", else: field.name)

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign(:name, name)
    |> assign(:value, assigns[:value] || field.value)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <label for={@id} class="flex items-center gap-2.5 mb-4 text-sm text-ink">
      <input
        type="hidden"
        name={@name}
        value="false"
        disabled={@rest[:disabled]}
        form={@rest[:form]}
      />
      <%!-- border-radius is inert on Chromium's native checkbox
           (appearance: auto) — kept for engines that honor it. --%>
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        class={@class || "size-4 rounded border-line-strong accent-primary"}
        {@rest}
      />{@label}
    </label>
    <.error :for={msg <- @errors}>{msg}</.error>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label for={@id}>
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-ink">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={control_class(assigns)}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label for={@id}>
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-ink">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={control_class(assigns) ++ ["min-h-24"]}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-4">
      <label for={@id}>
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-ink">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={control_class(assigns)}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Shared input chrome: control classes flip to danger when the field
  # has errors; caller class/error_class APPEND (the system contract —
  # "class is appended, never replaces"), so e.g. max-w-xs keeps the
  # base styling.
  defp control_class(%{errors: errors} = assigns) do
    base =
      "w-full rounded-control border bg-panel px-3 py-2 text-sm text-ink shadow-sm transition-[color,background-color,border-color,box-shadow] duration-(--motion-fast) placeholder:text-ink-subtle focus:outline-none focus:ring-2 disabled:opacity-50"

    state =
      if errors != [],
        do: "border-danger focus:border-danger focus:ring-danger/25",
        else: "border-line focus:border-line-primary focus:ring-focus/25"

    [base, state, assigns[:class], assigns[:error_class]]
    |> Enum.reject(&is_nil/1)
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-1.5 items-center text-xs text-danger">
      <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a rung slider (#221) — the selectable control for a discrete
  dimension (the deploy wizard's CPU/memory/storage, whose offerable
  values are the seeded ladder's rungs, not a continuous range).

  The input addresses the rungs **by index** — a native range input
  can only carry a uniform step, so it runs `0 … last rung` at `step
  1` and the rung *value* is the caller's to map (the wizard's
  `resources` params carry indices; the LiveView owns the arrays).
  The native semantics are then the detents themselves: one arrow
  press moves exactly one rung, Home/End jump to the ladder's ends,
  and the browser quantizes the thumb to whole rungs while dragging —
  it never rests between rungs. `aria-valuetext` announces the
  unit-bearing readout; the visible readout mirrors it and is
  `aria-hidden` — one value, not two. The tick row labels the rungs
  (equally spaced, like the thumb's index scale) and highlights the
  active one, so where you stopped is unmistakable.

  ## Examples

      <.slider
        id="resource-cpu-cores"
        name="resources[cpu_cores]"
        label="CPU cores"
        value="0.5"
        values={["0.25", "0.5", "1", "2", "4", "6", "8"]}
        unit="cores"
      />
  """
  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)

  attr(:value, :string,
    required: true,
    doc: "the current rung value, rendered as the thumb's position and the active tick"
  )

  attr(:values, :list,
    required: true,
    doc: "the dimension's rungs, ascending strings — the only values the control can express"
  )

  attr(:unit, :string, default: nil, doc: "shown beside the value and announced with it")
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def slider(assigns) do
    assigns =
      assign(assigns,
        readout: readout(assigns.value, assigns.unit),
        index: Enum.find_index(assigns.values, &(&1 == assigns.value)),
        top: length(assigns.values) - 1
      )

    ~H"""
    <div class={@class}>
      <div class="flex items-baseline justify-between gap-3">
        <label for={@id} class="text-sm font-medium text-ink">{@label}</label>
        <span class="font-mono text-sm font-semibold text-ink" aria-hidden="true">{@readout}</span>
      </div>
      <input
        type="range"
        id={@id}
        name={@name}
        value={@index}
        min="0"
        max={@top}
        step="1"
        aria-valuetext={@readout}
        class={[
          "mt-2 h-5 w-full cursor-pointer appearance-none bg-transparent",
          "outline-offset-4 outline-focus focus-visible:outline-2",
          "[&::-webkit-slider-runnable-track]:h-1.5 [&::-webkit-slider-runnable-track]:rounded-full [&::-webkit-slider-runnable-track]:bg-panel-sunken",
          "[&::-webkit-slider-thumb]:mt-[-5px] [&::-webkit-slider-thumb]:size-4",
          "[&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:rounded-full",
          "[&::-webkit-slider-thumb]:bg-primary [&::-webkit-slider-thumb]:[box-shadow:var(--elevation-sm)]",
          "[&::-moz-range-track]:h-1.5 [&::-moz-range-track]:rounded-full [&::-moz-range-track]:bg-panel-sunken",
          "[&::-moz-range-thumb]:size-4 [&::-moz-range-thumb]:rounded-full",
          "[&::-moz-range-thumb]:border-0 [&::-moz-range-thumb]:bg-primary"
        ]}
        {@rest}
      />
      <div id={"#{@id}-ticks"} class="relative mt-1.5 h-5 select-none" aria-hidden="true">
        <span
          :for={{rung, i} <- Enum.with_index(@values)}
          data-value={rung}
          data-active={if(i == @index, do: "true")}
          style={"left: #{tick_left(i, @top)}"}
          class="absolute top-0 flex -translate-x-1/2 flex-col items-center gap-1"
        >
          <span class={[
            "size-1.5 rounded-full transition-colors",
            if(i == @index, do: "bg-primary", else: "bg-line-strong")
          ]} />
          <span class={[
            "font-mono text-xs transition-colors",
            if(i == @index, do: "text-ink", else: "text-ink-subtle")
          ]}>
            {rung}
          </span>
        </span>
      </div>
    </div>
    """
  end

  defp readout(value, nil), do: to_string(value)
  defp readout(value, unit), do: "#{value} #{unit}"

  # A tick sits exactly under its thumb's CENTER: a native range input
  # parks the thumb at [T/2, W − T/2] (T = the thumb's 1rem width), not
  # [0, W] — so rung i sits at that band's fraction, not i/top of the
  # full width (which would drift up to half a thumb at the edges). A
  # single-rung ladder has no travel; the thumb parks at T/2.
  defp tick_left(_i, 0), do: "0.5rem"

  defp tick_left(i, top), do: "calc(0.5rem + (100% - 1rem) * #{Float.round(i / top, 4)})"

  @doc """
  Renders a page header with title, optional subtitle, and actions.

  ## Examples

      <.header>
        Catalog
        <:subtitle>One click from browse to a running instance.</:subtitle>
        <:actions><.button>Deploy</.button></:actions>
      </.header>
  """
  slot(:inner_block, required: true)
  slot(:subtitle)
  slot(:actions)

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex flex-wrap items-center justify-between gap-4", "pb-6"]}>
      <div>
        <h1 class="text-2xl font-semibold tracking-tight text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-ink-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a card — the system's primary surface for grouping content.

  ## Examples

      <.card>
        <h2 class="font-semibold">Balance</h2>
      </.card>
      <.card class="p-6">…</.card>
  """
  attr(:class, :any, default: nil, doc: "appended classes (e.g. padding overrides)")
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <div
      class={[
        "rounded-panel border border-line-strong bg-panel shadow-sm p-5",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a single-value metric on a card (#205's dashboard: balance,
  runway — the shape later widgets reuse).

  ## Examples

      <.metric_card label="Balance" value="$3.00" hint="Credits never expire." />
      <.metric_card label="Runway" value="≈ 2 months" hint="at $4.10/mo burn" />
  """
  attr(:label, :string, required: true, doc: "the metric's name (small, muted)")
  attr(:value, :string, required: true, doc: "the formatted value (large)")
  attr(:hint, :string, default: nil, doc: "one line of context under the value")
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def metric_card(assigns) do
    ~H"""
    <.card class={["flex items-start justify-between gap-4", @class]} {@rest}>
      <div class="min-w-0">
        <h2 class="text-sm font-medium text-ink-muted">{@label}</h2>
        <p class="mt-1 text-3xl font-bold tracking-tight text-ink">{@value}</p>
        <p :if={@hint} class="mt-1 text-xs text-ink-subtle">{@hint}</p>
      </div>
    </.card>
    """
  end

  @doc """
  Renders a small pill for metadata (categories, sizes, prices) or
  status. For instance lifecycle states use `status_badge/1`.

  ## Examples

      <.badge>2 CPU</.badge>
      <.badge tone="primary">$9/mo</.badge>
  """
  attr(:tone, :string, values: ~w(neutral primary success warning danger), default: "neutral")
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def badge(assigns) do
    tones = %{
      "neutral" => "border-line bg-panel-raised text-ink-muted",
      "primary" => "border-primary/25 bg-primary-muted text-link",
      "success" => "border-line-success bg-success-muted text-success",
      "warning" => "border-line-warning bg-warning-muted text-warning",
      "danger" => "border-line-danger bg-danger-muted text-danger"
    }

    assigns = assign(assigns, :class, [Map.fetch!(tones, assigns.tone), assigns[:class]])

    ~H"""
    <span
      class={[
        "fv-badge inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders an empty-state block (no instances yet, empty catalog, …).

  ## Examples

      <.empty_state title="No instances yet">
        Deploy your first app from the catalog.
      </.empty_state>
  """
  attr(:title, :string, required: true)
  attr(:class, :any, default: nil)
  slot(:inner_block, doc: "optional supporting copy below the title")

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center gap-1.5 rounded-panel border border-dashed border-line-strong bg-panel px-6 py-16 text-center",
      @class
    ]}>
      <p class="text-sm font-medium text-ink">{@title}</p>
      <p :if={@inner_block != []} class="text-sm text-ink-muted">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "the function for generating the row id")
  attr(:row_click, :any, default: nil, doc: "the function for handling phx-click on each row")

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"
  )

  slot :col, required: true do
    attr(:label, :string)
  end

  slot(:action, doc: "the slot for showing user actions in the last table column")

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <%!-- text-ink on the chrome: cells inherit it, so table text flips
    with the theme. Without it a dark panel leaked light-mode ink
    wherever the page didn't set a color (storybook, bare embeds). --%>
    <div class="overflow-x-auto rounded-panel border border-line bg-panel text-ink">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-line text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
            <th :for={col <- @col} class="px-4 py-3 font-medium">{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="border-b border-line last:border-0 transition-colors hover:bg-panel-raised/60"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={["px-4 py-3", @row_click && "hover:cursor-pointer"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 px-4 py-3 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr(:title, :string, required: true)
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-line">
      <li :for={item <- @item} class="flex gap-4 py-3">
        <div class="min-w-0 flex-1">
          <div class="text-sm font-medium text-ink">{item.title}</div>
          <div class="text-sm text-ink-muted">{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: "size-4")

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a button that copies `value` to the clipboard.

  The value rides a `data-` attribute rather than being read back out of
  the DOM: what the button copies is exactly what the server rendered, so
  a partial selection — a triple-click that catches the neighbouring
  label, a wrapped line — can't corrupt the copy (#194). Callers pass a
  unique `id`; the colocated hook keys off the element.

  ## Examples

      <.copy_button id="copy-url" value={@url} />
      <.copy_button id="copy-key" value={@key} label="Copy key" />
  """
  attr(:id, :string, required: true, doc: "unique DOM id — the hook's target")
  attr(:value, :string, required: true, doc: "the exact text to copy")
  attr(:label, :string, default: "Copy")
  attr(:testid, :string, default: nil, doc: "defaults to `id`")
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def copy_button(assigns) do
    assigns = assign(assigns, :testid, assigns.testid || assigns.id)

    ~H"""
    <button
      type="button"
      id={@id}
      class={[
        "inline-flex shrink-0 items-center gap-1.5 rounded-control border border-line bg-panel px-2 py-1",
        "text-xs font-medium text-ink-muted transition-colors hover:bg-panel-raised hover:text-ink",
        "data-[copied=true]:border-line-success data-[copied=true]:text-success",
        @class
      ]}
      phx-hook=".CopyToClipboard"
      data-copy-value={@value}
      data-testid={@testid}
      {@rest}
    >
      <.icon name="hero-clipboard" class="size-3.5" />
      <span data-copy-text>{@label}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.label = this.el.querySelector("[data-copy-text]")
          this.labelText = this.label.textContent
          this.el.addEventListener("click", () => this.write(this.el.dataset.copyValue || ""))
        },
        write(value) {
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(value).then(
              () => this.confirm(true),
              () => this.confirm(this.legacyWrite(value)),
            )
          } else {
            this.confirm(this.legacyWrite(value))
          }
        },
        // Async clipboard needs a secure context; a plain-http dev box
        // falls back to the selection dance.
        legacyWrite(value) {
          const area = document.createElement("textarea")
          area.value = value
          area.setAttribute("readonly", "")
          area.style.position = "fixed"
          area.style.opacity = "0"
          document.body.appendChild(area)
          area.select()
          let ok = false
          try {
            ok = document.execCommand("copy")
          } catch (_error) {
            ok = false
          }
          document.body.removeChild(area)
          return ok
        },
        confirm(written) {
          if (!written) return
          if (this.timer) clearTimeout(this.timer)
          this.label.textContent = "Copied"
          this.el.dataset.copied = "true"
          this.timer = setTimeout(() => {
            this.label.textContent = this.labelText
            delete this.el.dataset.copied
          }, 1500)
        },
      }
    </script>
    """
  end

  @doc """
  Renders a wizard progress stepper (deploy wizard, top-up wizard,
  #178 wave 2). Numbered chips on a hairline rail, in the working
  register: mono uppercase step labels, the amber `--focus` accent on
  the current chip (the travelled rail is decorative — it fails
  1.4.11's non-text bar on both surfaces it sits on; hostile-348 F5 —
  the chips carry state), done states in success. Done labels ride
  `--success-deep` — the stepper can sit on a sunken band (the deploy
  wizard), where plain `--success` falls under 4.5:1 (CodeRabbit
  #348) — and done discs carry a check glyph, the shape cue that
  survives colour-vision deficiency (hostile-348 F4). Labels track
  0.08em: at the eyebrow's 0.18em the top-up stepper's wrap cliff
  moves 115px (hostile-348 F1). Rail stubs hide below sm, where rows
  wrap.

  ## Examples

      <.stepper steps={[{"details", "Billing details"}, {"amount", "Amount"}]} current={1} />
      <.stepper steps={@steps} current={@current} testid_prefix="topup" />
  """
  attr(:steps, :list,
    required: true,
    doc: "{id, label} pairs in order; the id rides testids and is the stable key"
  )

  attr(:current, :integer,
    required: true,
    doc: "the current step's index (0-based); steps before it render done"
  )

  attr(:testid_prefix, :string,
    default: nil,
    doc: ~S{emits data-testid="<prefix>-stepper" / "<prefix>-step-<id>" when set}
  )

  def stepper(assigns) do
    ~H"""
    <ol
      class="flex flex-wrap items-center gap-2 font-mono text-xs uppercase tracking-[0.08em]"
      data-testid={@testid_prefix && "#{@testid_prefix}-stepper"}
    >
      <li
        :for={{step, index} <- Enum.with_index(@steps)}
        class={[
          "flex items-center gap-2",
          index < @current && "text-success-deep",
          index == @current && "font-semibold text-ink",
          index > @current && "text-ink-subtle"
        ]}
        data-testid={@testid_prefix && "#{@testid_prefix}-step-#{elem(step, 0)}"}
      >
        <span class={[
          "flex size-6 items-center justify-center rounded-full border text-xs font-medium",
          index < @current && "border-line-success bg-success-muted text-success",
          index == @current && "border-focus bg-focus/10 text-link",
          index > @current && "border-line bg-panel text-ink-subtle"
        ]}>
          <%!-- Shape cue for done (hostile-348 F4): the deep-green label is
          AA on the sunken band but near-no-op vs the todo grey for
          deuteranopes (dE 4.9), so the done disc carries a check instead
          of the number — the one cue that survives CVD. --%>
          <.icon :if={index < @current} name="hero-check" class="size-3.5" />
          <span :if={index >= @current}>{index + 1}</span>
        </span>
        {elem(step, 1)}
        <%!-- Rail stubs hide below sm: wrapped rows would end in a
        travelled-amber dash promising progress-continues-right into the
        next line (hostile-348 F6). >=sm stays one row — rails intact. --%>
        <span
          :if={index < length(@steps) - 1}
          class={[
            "hidden h-px w-6 sm:block",
            index < @current && "bg-focus/40",
            index >= @current && "bg-line"
          ]}
          aria-hidden="true"
        />
      </li>
    </ol>
    """
  end

  @doc """
  Renders a callout — an inline notice that deserves visual weight
  (warnings, first-run guidance, admin reveals).

  ## Examples

      <.callout tone="warning" title="Below the recommendation">
        It may run slowly or fail.
      </.callout>
  """
  attr(:tone, :string, values: ~w(info warning danger success), default: "info")
  attr(:title, :string, default: nil)
  attr(:icon, :string, default: nil, doc: "heroicon name; defaults per tone")
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def callout(assigns) do
    tones = %{
      "info" => "border-primary/25 bg-primary-muted",
      "warning" => "border-line-warning bg-warning-muted",
      "danger" => "border-line-danger bg-danger-muted",
      "success" => "border-line-success bg-success-muted"
    }

    icons = %{
      "info" => {"hero-information-circle", "text-link"},
      "warning" => {"hero-exclamation-triangle", "text-warning"},
      "danger" => {"hero-exclamation-circle", "text-danger"},
      "success" => {"hero-check-circle", "text-success"}
    }

    # Caller icon wins over the tone default (the attr's documented
    # contract — CodeRabbit #191: it was declared but ignored).
    {default_icon, icon_class} = Map.fetch!(icons, assigns.tone)
    icon_name = assigns.icon || default_icon

    assigns =
      assign(assigns,
        tone_class: Map.fetch!(tones, assigns.tone),
        icon: icon_name,
        icon_class: icon_class
      )

    ~H"""
    <div
      class={["rounded-panel border px-4 py-3 text-sm text-ink", @tone_class, @class]}
      {@rest}
    >
      <div class="flex items-start gap-2.5">
        <.icon name={@icon} class={["mt-0.5 size-4 shrink-0", @icon_class]} />
        <div class="min-w-0 flex-1 space-y-1.5">
          <p :if={@title} class="font-medium text-ink">{@title}</p>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a status badge — one per state-machine state, with a pulsing
  dot on the in-motion ones (deploying/starting/deleting; connecting/
  removing on the gateway). Serves both state machines: the Instance's
  (#74) and the AccessGateway's (ADR-0039) — no atom collides, so one
  component labels both. No DOM id: the badge appears once per row in
  lists, and ids must stay unique — assert via
  `[data-testid=status-badge]` + text. The label is #179's user-facing
  vocabulary (Submitted/Provisioning/…, Connecting/Connected/…), never
  the internal atom.
  """
  attr(:status, :atom, required: true)

  def status_badge(%{status: status} = assigns) do
    # {classes, dot} — dot pulses on in-motion states.
    {classes, dot} =
      case status do
        :pending -> {"border-line bg-panel-raised text-ink-muted", "static"}
        :deploying -> {"border-line-warning bg-warning-muted text-warning", "pulse"}
        :starting -> {"border-line-warning bg-warning-muted text-warning", "pulse"}
        :running -> {"border-line-success bg-success-muted text-success", "static"}
        # #203: asleep, not stopped — brand amber, a resting state the
        # next visitor reverses (distinct from stopped's neutral gray).
        :sleeping -> {"border-line bg-primary-muted text-link", "none"}
        :stopped -> {"border-line bg-panel-raised text-ink-muted", "none"}
        :error -> {"border-line-danger bg-danger-muted text-danger", "static"}
        :deleting -> {"border-line-danger bg-danger-muted text-danger", "pulse"}
        # #196: externally-deleted — an anomaly, not motion; danger
        # styling without the pulse.
        :lost -> {"border-line-danger bg-danger-muted text-danger", "static"}
        # ADR-0039's gateway states (the Access tab's badge):
        # connecting and removing are motion (pulse); needs_attention is
        # the owner's to fix (warning, no pulse); suspended is the
        # ladder's resting neutral, not a failure.
        :provisioning -> {"border-line-warning bg-warning-muted text-warning", "pulse"}
        :active -> {"border-line-success bg-success-muted text-success", "static"}
        :needs_attention -> {"border-line-warning bg-warning-muted text-warning", "static"}
        :suspended -> {"border-line bg-panel-raised text-ink-muted", "none"}
        :destroying -> {"border-line-danger bg-danger-muted text-danger", "pulse"}
        _other -> {"border-line bg-panel-raised text-ink-muted", "none"}
      end

    assigns =
      assign(assigns,
        classes: classes,
        dot: dot,
        label: badge_label(status)
      )

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium",
        @classes
      ]}
      data-testid="status-badge"
    >
      <span
        :if={@dot != "none"}
        class={["size-1.5 rounded-full bg-current", @dot == "pulse" && "motion-safe:animate-pulse"]}
      />
      {@label}
    </span>
    """
  end

  # Gateway labels (ADR-0039) live here — the #179 vocabulary, never the
  # internal atom. Instance states keep InstanceStatus's map.
  defp badge_label(status)
       when status in [:provisioning, :active, :needs_attention, :suspended, :destroying] do
    case status do
      :provisioning -> "Connecting"
      :active -> "Connected"
      :needs_attention -> "Needs attention"
      :suspended -> "Suspended"
      :destroying -> "Removing"
    end
  end

  defp badge_label(status), do: InstanceStatus.label(status)

  @doc """
  Renders a nav bar link (app chrome, public chrome, landing header).
  Active state is the round-3 chrome: ink text + the 2px amber
  underline (`--primary`) hanging to the nav's baseline — the header
  row's bottom edge. Inactive and hover keep the quiet muted
  treatment in both chromes (app + public). The active state is also
  exposed to assistive tech as `aria-current="page"`.

  ## Examples

      <.nav_link navigate={~p"/apps"} active={@active}>Catalog</.nav_link>
  """
  attr(:active, :boolean, default: false)
  attr(:class, :any, default: nil)
  attr(:rest, :global, include: ~w(href navigate patch method download))

  slot(:inner_block, required: true)

  def nav_link(assigns) do
    ~H"""
    <%!-- The underline's hang, on a stable box: inline-flex items-center
    fixes the link at a 32px flex box (py-1.5 + text-sm) — `top-full`
    resolves off THAT, not the font/DPR-dependent inline box. The header
    row is h-14 (56px) with items-center → 12px of clearance below the
    box; top-full + mt-2.5 (10px) + h-0.5 (2px) lands the underline flush
    with the header's border-b (gap 0). The mark rides --focus, not
    --primary: it carries state, so it clears the 1.4.11 3:1 non-text
    floor in light mode too — the same call the focus ring made (#277
    T2, app.css). --%>
    <.link
      aria-current={@active && "page"}
      class={[
        "nav_link relative inline-flex items-center rounded-control px-3 py-1.5 text-sm font-medium transition-colors",
        @active &&
          "text-ink after:absolute after:inset-x-3 after:top-full after:mt-2.5 after:h-0.5 after:bg-focus after:content-['']",
        !@active && "text-ink-muted hover:bg-panel-raised hover:text-ink",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Renders the signed-in user menu (#205): avatar bubble + dropdown —
  GitHub-style, replacing both the plain "Sign in" button and the
  email + sign-out text in every chrome. A native `<details>` dropdown:
  it needs zero JS on the dead marketing pages (phx-click bindings
  only fire with a live socket), toggles by keyboard, and closes on
  link navigation — the links are plain hrefs, so every navigation is
  a full page load and no live patch can strand the panel open.

  `app_links` folds the app chrome's header links (Catalog/Instances)
  into the dropdown below sm (#255): the header row — logo + three
  links + theme trio + this menu — overflows a 375px viewport by
  ~133px with the dropdown closed, so below sm the header links hide
  (`hidden sm:block`, app chrome's own `<li>`s) and reappear here
  (`sm:hidden` rows) — nothing is unreachable at any width.

  ## Examples

      <.user_menu username={@current_user.username} email={@current_user.primary_email} />
  """
  # #285 T4: the glyph and the panel's name line derive from the
  # username; the email line shows the account's PRIMARY address. Call
  # sites pass `User.primary_email` (the calculation) — falling back to
  # the frozen `users.email` mirror when nil (old-pod straggler, see the
  # calculation's comment); the component renders what it is given.
  attr(:username, :string, required: true, doc: "the account's handle — glyph + name line")

  attr(:email, :string,
    required: true,
    doc: "the account's primary address (callers fall back to the frozen mirror)"
  )

  attr(:app_links, :boolean,
    default: false,
    doc: "surface Catalog/Instances below sm (app chrome, #255)"
  )

  # The chrome's active-nav section (#319): below sm the header links
  # hide and these folded rows replace them, so the section's row marks
  # active — aria-current + ink/bold text, a menu-appropriate treatment
  # (the header's hanging underline is a header-row idiom, not a
  # dropdown-row one).
  attr(:nav_section, :atom, default: nil)

  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def user_menu(assigns) do
    assigns = assign(assigns, :name, menu_name(assigns.username, assigns.email))

    ~H"""
    <details data-testid="user-menu" class={["group relative", @class]} {@rest}>
      <summary
        class="flex cursor-pointer list-none items-center gap-1.5 rounded-full border border-line bg-panel p-1 pr-2.5 [box-shadow:var(--elevation-sm)] transition-colors hover:bg-panel-raised [&::-webkit-details-marker]:hidden"
        aria-label="Account menu"
        data-testid="user-menu-button"
      >
        <span
          class="grid size-7 place-items-center rounded-full bg-primary-muted text-xs font-semibold text-link"
          aria-hidden="true"
        >
          {initial(@name)}
        </span>
        <.icon
          name="hero-chevron-down-micro"
          class="size-3.5 text-ink-subtle transition-transform group-open:rotate-180"
        />
      </summary>
      <div
        class="absolute right-0 z-50 mt-2 w-56 rounded-panel border border-line-strong bg-panel p-1.5 [box-shadow:var(--elevation-lg)]"
        data-testid="user-menu-panel"
      >
        <p class="truncate px-3 py-2 text-xs font-medium text-ink" title={@name}>{@name}</p>
        <p class="truncate px-3 pb-2 text-xs text-ink-subtle" title={@email}>{@email}</p>
        <div class="my-1 border-t border-line" aria-hidden="true"></div>
        <%!-- #255: mobile-only surface rows — the header links these
        replace are hidden below sm, so no width shows both copies.
        #319: the section's row carries the active state (aria-current +
        ink/bold), the row idiom for what the header underlines. --%>
        <.link
          :if={@app_links}
          href={~p"/apps"}
          aria-current={@nav_section == :catalog && "page"}
          class={[
            "block rounded-control px-3 py-1.5 text-sm transition-colors sm:hidden",
            @nav_section == :catalog && "font-semibold text-ink",
            @nav_section != :catalog && "text-ink-muted hover:bg-panel-raised hover:text-ink"
          ]}
        >
          Catalog
        </.link>
        <.link
          :if={@app_links}
          href={~p"/instances"}
          aria-current={@nav_section == :instances && "page"}
          class={[
            "block rounded-control px-3 py-1.5 text-sm transition-colors sm:hidden",
            @nav_section == :instances && "font-semibold text-ink",
            @nav_section != :instances && "text-ink-muted hover:bg-panel-raised hover:text-ink"
          ]}
        >
          Instances
        </.link>
        <%!-- href, not navigate: full page loads close the dropdown on
        every surface — a live patch would strand it open (#205).
        sm:hidden like its siblings: on desktop the header link owns
        Billing (and its active mark) — two simultaneous marks for one
        section read as a bug (#319 hostile 12a). --%>
        <.link
          href={~p"/billing"}
          aria-current={@nav_section == :billing && "page"}
          class={[
            "block rounded-control px-3 py-1.5 text-sm transition-colors sm:hidden",
            @nav_section == :billing && "font-semibold text-ink",
            @nav_section != :billing && "text-ink-muted hover:bg-panel-raised hover:text-ink"
          ]}
        >
          Billing
        </.link>
        <%!-- #285 T5: account settings — a link row like the others;
        href, not navigate, the same close-on-click posture (#205). --%>
        <.link
          href={~p"/settings"}
          class="block rounded-control px-3 py-1.5 text-sm text-ink-muted transition-colors hover:bg-panel-raised hover:text-ink"
          data-testid="user-menu-settings"
        >
          Account settings
        </.link>
        <.link
          href={~p"/about"}
          class="block rounded-control px-3 py-1.5 text-sm text-ink-muted transition-colors hover:bg-panel-raised hover:text-ink"
        >
          About FluxVale
        </.link>
        <div class="my-1 border-t border-line" aria-hidden="true"></div>
        <form action={~p"/auth/session"} method="post">
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button
            type="submit"
            class="block w-full cursor-pointer rounded-control px-3 py-1.5 text-left text-sm text-ink-muted transition-colors hover:bg-panel-raised hover:text-ink"
          >
            Sign out
          </button>
        </form>
      </div>
    </details>
    """
  end

  # The avatar glyph: the first grapheme, uppercased — no external
  # avatar source in v1. Emails are CiStrings at the Ash boundary;
  # downcast before String owns it. Defensively empty/nil-safe: the
  # column admits '' on raw writes and seeds (create/update both
  # reject it), nil is impossible past the not-null column — the nil
  # clause is belt-and-braces on shared chrome, so a neutral glyph
  # renders instead of a crash (the glyph is aria-hidden decoration,
  # so nothing is announced either way).
  defp initial(nil), do: "?"
  defp initial(""), do: "?"

  defp initial(subject) do
    subject
    |> to_string()
    |> String.first()
    |> String.upcase()
  end

  # The menu's name line + glyph source (#285 T4): the username when
  # present, else the (primary) address's local part — rollout-window
  # rows carry a NULL username (T2 derivation shipped with #285), and
  # an empty name line or a bare "?" glyph is worse than the handle the
  # address implies. Same degradation the org switcher's personal row
  # uses (OrgNav.display_handle/1).
  defp menu_name(username, _email) when username not in [nil, ""], do: username
  defp menu_name(_username, email), do: local_part(email)

  defp local_part(email) do
    address = to_string(email)
    [local_part | _domain] = String.split(address, "@", parts: 2)
    local_part
  end

  @doc """
  Renders the org switcher (#276): the app chrome's context dropdown —
  exactly one row per membership (`actor_orgs`, resolved by the
  `FluxValeWeb.OrgNav` on_mount). The actor's owned org renders as
  **"Personal — `<username>`"** — bare "Personal" when the handle is
  nil or empty (OrgNav's email fallback can yield "" for a degenerate
  address); other orgs render name + slug. The
  personal context IS an org (#285 T6), so there is no hardcoded
  "Personal" chrome row and no single-org suppression — the redundancy
  dies at the root. But it never presents as one (S5): the personal row
  targets the dashboard `/` — the org-scoped URLs redirect, the personal
  account's surfaces are user settings — while real orgs link their org
  home. A native `<details>` dropdown for the same reasons
  as `user_menu`: keyboard-toggleable, plain-href rows that close it on
  navigation (full page load — no live patch can strand the panel
  open); the one JS is the shared DetailsDismiss hook for GitHub-style
  dismissal (outside click + Esc).

  `current_org` names the active context in the closed summary. With no
  org context set the pill reads "Personal" — but only when a personal
  org both resolves (`personal_org_id`) and sits among the rows: a
  member-only or zero-org actor has no personal context, and the pill
  must not claim one (#285 T6 review); nor when OrgNav's two
  non-transactional reads straddle a membership change and leave
  `personal_org_id` absent from `orgs` (#308 review) — it degrades to
  the bare building glyph. Below
  lg the summary collapses to the glyph: the active org's initial (the
  user_menu pattern — the building icon can't say which org is active),
  the building icon for Personal. At `sm` a label would occlude the
  first nav link (the 640-712px band — a pill of intrinsic width over a
  shrunken cluster, #276 review), and above lg `truncate` bounds a long
  active name. The panel keeps every entry reachable.

  ## Examples

      <.org_switcher orgs={@actor_orgs} personal_org_id={@personal_org_id} username={@username} />
  """
  attr(:orgs, :list,
    default: [],
    doc:
      "the actor's memberships with :organization loaded (OrgNav's actor_orgs); " <>
        "component-level callers may pass plain maps — :id is only read for the personal row"
  )

  attr(:personal_org_id, :string,
    default: nil,
    doc: "the owned (personal) org's id — OrgNav's personal_org_id; its row is the Personal one"
  )

  attr(:username, :string, default: nil, doc: "the actor's handle — labels the personal row")

  attr(:current_org, :map, default: nil, doc: "the active org; nil = personal context")

  attr(:id, :string,
    default: "org-switcher",
    doc: "unique DOM id — the DetailsDismiss hook's target"
  )

  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def org_switcher(assigns) do
    assigns =
      assign(
        assigns,
        :active_name,
        active_name(assigns.current_org, assigns.personal_org_id, assigns.orgs)
      )

    ~H"""
    <details
      id={@id}
      phx-hook="DetailsDismiss"
      data-testid="org-switcher"
      class={["group relative", @class]}
      {@rest}
    >
      <summary
        class="flex cursor-pointer list-none items-center gap-1 rounded-full border border-line bg-panel py-1 pr-1.5 pl-2 [box-shadow:var(--elevation-sm)] transition-colors hover:bg-panel-raised [&::-webkit-details-marker]:hidden"
        aria-label="Organization switcher"
        data-testid="org-switcher-button"
      >
        <%!-- Below lg the summary carries no label, so a set context
        names itself by its initial (the user_menu glyph) — the building
        icon alone cannot say which org is active. Personal keeps the
        icon; above lg both show the icon beside the truncated name. --%>
        <span
          :if={@current_org}
          aria-hidden="true"
          class="grid size-4 shrink-0 place-items-center overflow-hidden rounded-full bg-primary-muted text-[9px] font-semibold text-link lg:hidden"
        >
          {initial(@current_org.name)}
        </span>
        <.icon
          name="hero-building-library-micro"
          class={["size-4 shrink-0 text-ink-subtle", @current_org && "hidden lg:block"]}
        />
        <%!-- The label only renders when there is one to show — the
        empty-context state (no org context, no personal org) is the
        bare glyph, no text at all (see active_name/3). --%>
        <span
          :if={@active_name}
          class="hidden max-w-32 truncate text-xs font-semibold text-ink lg:inline"
        >{@active_name}</span>
        <.icon
          name="hero-chevron-down-micro"
          class="size-3 text-ink-subtle transition-transform group-open:rotate-180"
        />
      </summary>
      <div
        class="absolute left-0 z-50 mt-2 w-56 rounded-panel border border-line-strong bg-panel p-1.5 [box-shadow:var(--elevation-lg)]"
        data-testid="org-switcher-panel"
      >
        <p class="px-3 py-1.5 text-xs text-ink-subtle">Contexts</p>
        <div class="mb-1 border-t border-line" aria-hidden="true"></div>
        <%!-- href, not navigate: full page loads close the dropdown, the
        user_menu's reason (#205). Exactly one row per membership
        (#285 T6) — the owned org (personal_org_id) is the personal
        context and renders as its Personal—username label, targeting
        the dashboard (S5: its org-scoped URLs redirect). The
        personal_org_id guard stays falsy for callers that pass no
        personal_org_id or orgs without an :id (component-level maps)
        — every row renders name + slug there. --%>
        <.link
          :for={membership <- @orgs}
          href={row_href(membership.organization, @personal_org_id)}
          class="flex items-baseline gap-1 rounded-control px-3 py-1.5 text-sm text-ink-muted transition-colors hover:bg-panel-raised hover:text-ink"
        >
          <%= if personal_row?(membership.organization, @personal_org_id) do %>
            <span class="truncate">{personal_label(@username)}</span>
          <% else %>
            <%!-- min-w-0/truncate pair: a 39-char username (the #296 name
            ceiling) must clip inside the w-56 panel, not push the page
            into sideways scroll at phone widths (measured: +166px at
            375 open, gate-2 F1). --%>
            <span class="truncate">{membership.organization.name}</span>
            <span class="truncate font-mono text-xs text-ink-subtle">
              {membership.organization.slug}
            </span>
          <% end %>
        </.link>
      </div>
    </details>
    """
  end

  # The closed switcher's label: the active org's name; "Personal" when
  # no org context is set and a Personal row backs the claim — the
  # personal org must both resolve (personal_org_id) and be among the
  # loaded rows. A member-only or zero-org actor has no personal
  # context, and the pill must not claim one (#285 T6 review); and the
  # rows gate also covers the split state (#308 review): OrgNav's two
  # reads (memberships, then the canonical op) are not transactional,
  # so a membership change straddling them can leave personal_org_id
  # naming an org absent from @orgs — the pill degrades to the bare
  # building glyph rather than claim a context with no row.
  defp active_name(%{name: name}, _personal_org_id, _orgs), do: name
  defp active_name(nil, nil, _orgs), do: nil

  defp active_name(nil, personal_org_id, orgs) do
    personal_row? = Enum.any?(orgs, &(Map.get(&1.organization, :id) == personal_org_id))

    if personal_row? do
      "Personal"
    end
  end

  # The personal row's label: "Personal — username"; bare "Personal"
  # when the handle is nil or "" — the email fallback's local_part of a
  # degenerate address is "" (#308 review), the same dangling
  # "Personal — " hazard as nil (#285 T6 review).
  defp personal_label(username) when username in [nil, ""], do: "Personal"
  defp personal_label(username), do: "Personal — #{username}"

  # The personal row IS the user's account (S5) — it targets the
  # dashboard, the surface its instances and balance already live on;
  # the personal org's org-scoped URLs redirect. Real orgs keep their
  # org home. Same guard as the label branch below: falsy without a
  # personal_org_id or for orgs without an :id (component-level maps).
  defp row_href(org, personal_org_id) do
    if personal_row?(org, personal_org_id) do
      ~p"/"
    else
      ~p"/organizations/#{org.slug}"
    end
  end

  defp personal_row?(_org, nil), do: false

  defp personal_row?(org, personal_org_id) do
    Map.get(org, :id) == personal_org_id
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-[opacity,translate,scale] ease-(--motion-ease-out) duration-(--motion-slow)",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-[opacity,translate,scale] ease-in duration-(--motion-base)",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want to
    # translate as a static argument:
    #
    #     # Translate the plural forms of the number of files
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(FluxValeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(FluxValeWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
