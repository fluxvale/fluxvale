defmodule FluxValeWeb.PricingCalculatorLive do
  @moduledoc """
  The /pricing calculator (#440): THE pricing surface — resource sliders
  in, one curve-priced total out (the PikaPods pattern: nothing
  decomposes the concave curve, so no per-resource costs show). Every
  figure prices through FluxVale.Pricing.price_allocation/1 — the same
  call the ledger prices custom allocations through, so the shown price
  is the charged price by construction. The running total renders via
  `format_monthly_rate/1` and the stopped rate via `format_usd/1` plus
  " while stopped".

  Setups are line items (#469): the mount is a working calculator —
  the default rungs live-price the hero, no app needed, so the first
  paint carries rates. An app choice is required only to ADD: the Add
  button stays disabled until one is chosen, because the row carries
  the app's name, logo, and allocation. Picking an app snaps the
  sliders to its latest version's recommended size when the sliders
  can state it, and otherwise leaves the rungs where they are; the
  recommendation line names the app and the amount, and a nil or
  off-ladder recommendation renders no line (never a guessed one).
  After a manual edit the line stays and offers "Use recommended",
  which restores the snapped allocation. Add appends the current
  configuration as a row and resets — chooser emptied, rungs back to
  the default — for the next setup. Rows are removable and never
  collapse: two identical setups are two rows. Once rows exist the
  hero totals them (plus the gateway once, below) and the setup being
  built prices at the Add button instead.

  Other services ride inside the calculator as toggles: the gateway
  adds its exact flat rate from the accessor to the displayed total —
  once per organization whatever the row count, the way it bills —
  and its line item shows its own price. Custom domains are not in
  the calculator (ADR-0040 Amendment 2 made them free, so there is
  no cost to estimate; the topped-up account gate lives in policy
  land on AccessDomain :register). The sliders are
  FluxValeWeb.AllocationSliders verbatim (the deploy wizard's
  component); its DOM ids are page-unique by contract, and the wizard
  is a different page, so the calculator reuses them as-is.

  The /pricing controller page embeds this view with `live_render` (the
  PageController → DashboardLive precedent), so the initial render is
  SSR and crawlers see a formed calculator state. Anonymous-OK like its
  host page: reads ride the public read policies with no actor, and the
  session the embed rode is used only to re-resolve the locale — this
  view sits in no live_session, so no on_mount carries the hook.

  Seeded sizes are internal presets now (#440 took the tiers off the
  page): the mount resolves its starting allocation from them and
  renders no size names.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.App
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxValeWeb.AllocationSliders
  alias FluxValeWeb.Locale

  # Default state (#397): the `small` rungs, resolved by slug at mount —
  # never a literal index.
  @default_size_slug "small"

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # No live_session carries the locale hook for a controller-embedded
    # child, so mount re-resolves it from the session the embed rode —
    # the same resolver the :authenticated live_session's first on_mount
    # runs (Locale's moduledoc: one resolver per render path).
    Gettext.put_locale(FluxValeWeb.Gettext, Locale.resolve(session))

    sizes = sorted_sizes()
    default_resources = initial_resources(sizes)

    socket =
      socket
      |> assign(:sizes, sizes)
      |> assign(:apps, chooser_apps())
      |> assign(:default_resources, default_resources)
      |> assign(:resources, default_resources)
      |> assign(:app_slug, nil)
      |> assign(:app_name, nil)
      |> assign(:app_icon_url, nil)
      |> assign(:recommendation, nil)
      |> assign(:app_filter, "")
      |> assign(:app_picked, false)
      |> assign(:estimate, [])
      |> assign(:next_item_id, 1)
      |> stream(:estimate_items, [])
      |> assign(:services, %{gateway: false})
      |> assign(:gateway_monthly_cents, AccessGateway.monthly_cents())

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # The totals derive here so no render can disagree with the state.
    # Before the first Add the live configuration IS the estimate (the
    # classic calculator: every slider move re-prices the hero), and
    # once rows exist the estimate is the committed rows — the setup
    # being built then prices at the Add button instead. The gateway
    # serves the whole organization and bills once whatever the row
    # count, and it settles continuously regardless of instance state,
    # so the stopped line owes it too.
    price = pricing(assigns.resources)
    service_cents = enabled_service_cents(assigns)
    live_figure = estimate_cents(assigns.estimate)
    rows? = assigns.estimate != []

    hero_monthly = if(rows?, do: live_figure.monthly, else: price.monthly_cents) + service_cents

    hero_stopped =
      if(rows?, do: live_figure.stopped, else: price.stopped_monthly_cents) + service_cents

    assigns =
      assign(assigns,
        price: price,
        filtered_apps: filtered_apps(assigns.apps, assigns.app_filter),
        total_cents: hero_monthly,
        stopped_cents: hero_stopped,
        rows?: rows?
      )

    ~H"""
    <div class="space-y-4" data-testid="pricing-calculator">
      <div class="space-y-1">
        <h2 class="text-lg font-semibold tracking-tight text-ink">
          {gettext("Cost calculator")}
        </h2>
        <p class="text-sm text-ink-muted">
          {gettext("Pick an app, set its resources, then add instances to the estimate.")}
        </p>
      </div>

      <.card class="space-y-6 p-6 sm:p-8">
        <div class="space-y-2">
          <p class="text-sm font-medium text-ink" id="calculator-apps-label">
            {gettext("Pick an app")}
          </p>
          <div class="flex items-start gap-2">
            <%!-- A typed filter over real buttons (#463). Native
            controls, not an ARIA combobox: the panel shows while focus
            is inside this group, so Tab reaches every result and Enter
            activates it with no JS. `app_picked` closes the panel after
            a choice until the field is focused or typed in again. --%>
            <form
              id="calculator-app-form"
              phx-change="filter-apps"
              phx-submit="filter-apps"
              class="group relative flex-1"
            >
              <input
                type="search"
                id="calculator-app-filter"
                name="app_filter"
                value={@app_filter}
                phx-focus="open-apps"
                phx-keydown="close-apps"
                phx-key="Escape"
                aria-labelledby="calculator-apps-label"
                aria-describedby="calculator-apps-caption"
                autocomplete="off"
                placeholder={gettext("Search apps")}
                class="w-full rounded-lg border border-line bg-panel px-3 py-2 text-sm text-ink outline-offset-2 outline-focus placeholder:text-ink-subtle focus-visible:border-line-strong focus-visible:outline-2"
              />
              <div
                :if={not @app_picked}
                class="absolute z-10 mt-1 hidden w-full overflow-hidden rounded-lg border border-line bg-panel shadow-lg group-focus-within:block"
              >
                <ul :if={@filtered_apps != []} class="max-h-64 overflow-y-auto py-1">
                  <li :for={chooser <- @filtered_apps}>
                    <button
                      type="button"
                      phx-click="pick-app"
                      phx-value-slug={chooser.app.slug}
                      data-testid={"calculator-app-option-#{chooser.app.slug}"}
                      aria-pressed={if(@app_slug == chooser.app.slug, do: "true", else: "false")}
                      class={[
                        "flex w-full items-center gap-3 px-3 py-2 text-left text-sm transition-colors outline-offset-2 outline-focus hover:bg-panel-raised focus-visible:outline-2",
                        if(@app_slug == chooser.app.slug,
                          do: "bg-primary-muted text-ink",
                          else: "text-ink"
                        )
                      ]}
                    >
                      <span class="grid size-7 shrink-0 place-items-center rounded-control bg-primary-muted text-xs font-semibold text-link">
                        <img
                          :if={chooser.app.icon_url}
                          src={chooser.app.icon_url}
                          alt=""
                          class="size-5 rounded-control"
                        />
                        <span :if={is_nil(chooser.app.icon_url)}>
                          {String.first(chooser.app.name)}
                        </span>
                      </span>
                      <span class="min-w-0 flex-1 truncate">{chooser.app.name}</span>
                    </button>
                  </li>
                </ul>
                <p
                  :if={@filtered_apps == []}
                  class="px-3 py-3 text-sm text-ink-muted"
                  data-testid="calculator-app-no-results"
                >
                  {gettext("No apps match your search.")}
                </p>
              </div>
            </form>
            <button
              type="button"
              id="calculator-app-clear"
              phx-click="clear-app"
              class="rounded-lg border border-line bg-panel px-3 py-2 text-sm font-medium text-ink transition-colors outline-offset-2 outline-focus hover:border-line-strong hover:bg-panel-raised focus-visible:outline-2"
            >
              {gettext("Clear")}
            </button>
          </div>
          <p class="text-xs text-ink-subtle" id="calculator-apps-caption">
            {gettext("The price depends only on the allocation, never the app.")}
          </p>
        </div>

        <%!-- The recommendation line names the app and the amount. No
        recommendation means no line, never a guessed one. --%>
        <div
          :if={@recommendation}
          class="flex flex-wrap items-center justify-between gap-3 rounded-xl bg-panel-raised px-4 py-3 text-sm"
          data-testid="calculator-app-recommendation"
        >
          <div class="min-w-0 space-y-0.5">
            <p class="text-ink">
              {gettext("%{app} recommends this amount of resources", app: @app_name)}
            </p>
            <p class="font-mono text-ink-muted" data-testid="calculator-recommended-allocation">
              {size_text(@recommendation)}
            </p>
          </div>
          <button
            :if={not at_recommendation?(@resources, @recommendation)}
            type="button"
            id="calculator-use-recommended"
            phx-click="use-recommended"
            class="rounded-lg border border-line bg-panel px-3 py-1.5 text-sm font-medium text-ink transition-colors outline-offset-2 outline-focus hover:border-line-strong hover:bg-panel-raised focus-visible:outline-2"
          >
            {gettext("Use recommended")}
          </button>
        </div>

        <form id="calculator-resources-form" phx-change="resources-change">
          <AllocationSliders.sliders resources={@resources} />
        </form>

        <%!-- Add: gated on a chosen app, because the row carries the
        app's name, logo, and allocation. Once rows exist the hero
        totals them, so the setup being built prices here instead. --%>
        <div
          class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-line px-4 py-3 text-sm"
          data-testid="calculator-add-block"
        >
          <div :if={@rows?} class="min-w-0 space-y-0.5">
            <p class="text-xs uppercase tracking-wide text-ink-subtle">
              {gettext("This setup")}
            </p>
            <p
              class="font-mono font-medium text-ink"
              data-testid="calculator-setup-price"
              aria-live="polite"
            >
              {Pricing.format_monthly_rate(@price.monthly_cents)}
            </p>
            <p class="text-xs text-ink-subtle" data-testid="calculator-setup-allocation">
              {allocation_text(@resources)}
            </p>
            <p class="text-xs text-ink-subtle" data-testid="calculator-setup-stopped">
              {gettext(
                "%{rate}/mo while stopped",
                rate: Pricing.format_usd(@price.stopped_monthly_cents)
              )}
            </p>
          </div>
          <%!-- #471: this was text-primary-foreground + hover:bg-primary-strong —
          tokens the design system never defined, so the label inherited the
          ambient ink (white-on-amber in dark) and hover was a no-op. --%>
          <button
            type="button"
            id="calculator-add-instances"
            phx-click="add-instance"
            disabled={is_nil(@app_slug)}
            data-testid="calculator-add-instances"
            class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-on-primary transition-colors outline-offset-2 outline-focus hover:bg-primary-hover focus-visible:outline-2 disabled:cursor-not-allowed disabled:opacity-40"
          >
            {gettext("Add more instances")}
          </button>
        </div>

        <div class="space-y-2">
          <p class="text-sm font-medium text-ink">{gettext("Other services")}</p>
          <%!-- Each toggle's line item shows its own flat price; enabling
          the gateway adds exactly those accessor cents to the total
          below, once per organization whatever the row count. --%>
          <form id="calculator-services-form" phx-change="services-change" class="space-y-2">
            <%!-- Always-serialized marker: a form whose checkboxes are all
            unchecked serializes no services keys at all, so unchecking the
            last box would arrive as silence and freeze a stale total.
            The marker guarantees a services param exists, and the
            service is then on exactly when its own key says "on". --%>
            <input type="hidden" name="services[_marker]" value="1" />
            <div class="rounded-xl border border-line bg-panel px-4 py-3 text-sm">
              <label
                class="flex items-center justify-between gap-3 transition-colors hover:text-ink"
                data-testid="service-toggle-gateway"
              >
                <span class="flex items-center gap-3">
                  <input
                    type="checkbox"
                    name="services[gateway]"
                    value="on"
                    checked={@services.gateway}
                    class="h-4 w-4 accent-primary"
                  />
                  <span class="block font-medium text-ink">
                    {gettext("Private access gateway")}
                  </span>
                </span>
                <span class="font-medium text-ink">
                  {gettext(
                    "+%{rate}/mo per gateway, billed hourly",
                    rate: Pricing.format_usd(@gateway_monthly_cents)
                  )}
                </span>
              </label>
              <p class="mt-2 text-xs text-ink-subtle" data-testid="gateway-explainer">
                {gettext(
                  "Built on Tailscale: private access to your apps without public exposure. One gateway serves your whole organization and bills once, hourly. Set it up in Settings → Access."
                )}
              </p>
            </div>
          </form>
        </div>

        <%!-- The estimate rows (#469): one row per added setup — the
        app, its logo, the chosen allocation, and the row's own price,
        so the hero's aggregate is verifiable by eye. Rows never
        collapse: two identical setups are two rows, each removable on
        its own. --%>
        <div :if={@rows?} class="space-y-2" data-testid="calculator-estimate">
          <p class="text-sm font-medium text-ink">{gettext("Estimate")}</p>
          <div id="estimate-items" phx-update="stream" class="space-y-2">
            <div
              :for={{item_id, item} <- @streams.estimate_items}
              id={item_id}
              data-testid={"estimate-item-#{item.id}"}
              class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-line bg-panel px-4 py-3 text-sm"
            >
              <div class="flex min-w-0 items-center gap-3">
                <span class="grid size-7 shrink-0 place-items-center rounded-control bg-primary-muted text-xs font-semibold text-link">
                  <img
                    :if={item.icon_url}
                    src={item.icon_url}
                    alt=""
                    class="size-5 rounded-control"
                  />
                  <span :if={is_nil(item.icon_url)}>{String.first(item.app_name)}</span>
                </span>
                <span class="min-w-0 space-y-0.5">
                  <span
                    class="block truncate font-medium text-ink"
                    data-testid={"estimate-app-#{item.id}"}
                  >
                    {item.app_name}
                  </span>
                  <span
                    class="block font-mono text-xs text-ink-muted"
                    data-testid={"estimate-allocation-#{item.id}"}
                  >
                    {allocation_text(item.resources)}
                  </span>
                </span>
              </div>
              <div class="flex items-center gap-3">
                <span
                  class="font-mono font-medium text-ink"
                  data-testid={"estimate-price-#{item.id}"}
                >
                  {Pricing.format_monthly_rate(pricing(item.resources).monthly_cents)}
                </span>
                <button
                  type="button"
                  phx-click="remove-item"
                  phx-value-id={item.id}
                  data-testid={"estimate-remove-#{item.id}"}
                  class="rounded-lg border border-line bg-panel px-3 py-1.5 text-sm font-medium text-ink transition-colors outline-offset-2 outline-focus hover:border-line-strong hover:bg-panel-raised focus-visible:outline-2"
                >
                  {gettext("Remove")}
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- The hero number (#440): the live configuration before the
        first Add, the committed rows after, plus the gateway —
        prominent, announcing updates (the top-up wizard's aria-live
        pattern). --%>
        <div
          class="flex flex-wrap items-center justify-between gap-4 rounded-xl bg-panel-raised px-4 py-4 text-sm sm:px-6"
          data-testid="calculator-price"
        >
          <div class="space-y-1">
            <p class="text-xs uppercase tracking-wide text-ink-subtle">
              {gettext("Estimated total")}
            </p>
            <p
              class="text-3xl font-semibold tracking-tight text-ink"
              data-testid="calculator-total"
              aria-live="polite"
            >
              {Pricing.format_monthly_rate(@total_cents)}
            </p>
            <p class="text-ink-muted" data-testid="calculator-price-stopped">
              {gettext(
                "%{rate}/mo while stopped",
                rate: Pricing.format_usd(@stopped_cents)
              )}
            </p>
          </div>
          <span
            :if={not @rows?}
            class="font-mono text-ink-muted"
            data-testid="calculator-allocation"
          >
            {allocation_text(@resources)}
          </span>
        </div>
      </.card>
    </div>
    """
  end

  # Live: every slider move re-prices through the anchor formula. Absent
  # keys carry no opinion and a crafted index that names no rung is
  # dropped (AllocationSliders.resource_strings/1), so the merge keeps
  # the current rungs for anything undecodable.
  @impl Phoenix.LiveView
  def handle_event("resources-change", %{"resources" => params}, socket) when is_map(params) do
    resources = Map.merge(socket.assigns.resources, AllocationSliders.resource_strings(params))
    {:noreply, assign(socket, :resources, resources)}
  end

  # A crafted payload whose resources value is not a map decodes to
  # nothing — silence, like any unmatched shape.
  def handle_event("resources-change", _params, socket), do: {:noreply, socket}

  # The app chooser: a pick snaps the sliders to the latest version's
  # recommended size when the sliders can state it, and otherwise
  # selects the app and leaves the rungs alone — the sliders are a
  # working calculator with or without an app, so a recommendation-less
  # pick has nothing to snap and nothing to reset. The recommendation
  # is remembered so the line survives manual edits. A nil or
  # off-ladder recommendation renders no line: no snap, no guessed
  # amount. The choice is a start-from picker, not a promise about the
  # rungs, so the selection stays after a snap while the sliders move.
  @impl Phoenix.LiveView
  def handle_event("pick-app", %{"slug" => slug}, socket) when is_binary(slug) do
    case Enum.find(socket.assigns.apps, &(&1.app.slug == slug)) do
      nil ->
        {:noreply, socket}

      chooser ->
        {:noreply, select_app(socket, chooser)}
    end
  end

  # A crafted payload whose slug value is not a string decodes to
  # nothing — silence, like any unmatched shape.
  def handle_event("pick-app", _params, socket), do: {:noreply, socket}

  # The typed filter. Every keystroke reopens the panel and narrows the
  # list; a crafted non-string payload is silence.
  def handle_event("filter-apps", %{"app_filter" => text}, socket) when is_binary(text) do
    {:noreply, assign(socket, app_filter: text, app_picked: false)}
  end

  def handle_event("filter-apps", _params, socket), do: {:noreply, socket}

  # Focusing the field reopens the panel after a pick closed it.
  def handle_event("open-apps", _params, socket) do
    {:noreply, assign(socket, :app_picked, false)}
  end

  # Escape closes the panel but keeps the field focused. Typing reopens
  # it (the filter change above).
  def handle_event("close-apps", _params, socket) do
    {:noreply, assign(socket, :app_picked, true)}
  end

  # "Use recommended": restores the remembered allocation after manual
  # edits. No recommendation means a crafted click has nothing to
  # restore.
  def handle_event("use-recommended", _params, socket) do
    case socket.assigns.recommendation do
      nil ->
        {:noreply, socket}

      size ->
        {:noreply, assign(socket, :resources, size_resources(size))}
    end
  end

  # Add (#469): the current configuration becomes a row — the app's
  # name, logo, and the chosen allocation — and the calculator resets
  # for the next setup: chooser emptied, rungs back to the default.
  # The gate is the chosen app (the row needs it), so a crafted click
  # with nothing chosen is silence.
  def handle_event("add-instance", _params, socket) do
    if socket.assigns.app_slug do
      item = %{
        id: socket.assigns.next_item_id,
        app_name: socket.assigns.app_name,
        icon_url: socket.assigns.app_icon_url,
        resources: socket.assigns.resources
      }

      estimate = socket.assigns.estimate ++ [item]

      {:noreply,
       socket
       |> assign(:estimate, estimate)
       |> assign(:next_item_id, item.id + 1)
       |> stream(:estimate_items, estimate, reset: true)
       |> assign(:resources, socket.assigns.default_resources)
       |> clear_selection()}
    else
      {:noreply, socket}
    end
  end

  # Remove: rows are independent, so one id drops exactly one row (an
  # identical setup elsewhere in the estimate keeps its own). A crafted
  # id that names no row, or does not parse as one, is silence.
  def handle_event("remove-item", %{"id" => id}, socket) when is_binary(id) do
    case Integer.parse(id) do
      {item_id, ""} ->
        estimate = Enum.reject(socket.assigns.estimate, &(&1.id == item_id))

        {:noreply,
         socket
         |> assign(:estimate, estimate)
         |> stream(:estimate_items, estimate, reset: true)}

      _crafted ->
        {:noreply, socket}
    end
  end

  def handle_event("remove-item", _params, socket), do: {:noreply, socket}

  # The explicit Clear: deselects the app, forgets its recommendation,
  # empties the filter, and puts the rungs back to the default — the
  # same reset an Add leaves behind, so the next setup starts clean.
  def handle_event("clear-app", _params, socket) do
    {:noreply,
     socket
     |> assign(:resources, socket.assigns.default_resources)
     |> clear_selection()}
  end

  # Service toggles: a checkbox change serializes only the checked
  # boxes, so the gateway is on exactly when its key arrives. Unknown
  # keys (a crafted or stale payload naming a retired service) read as
  # nothing, and a services value that is not a map decodes to nothing.
  def handle_event("services-change", %{"services" => services}, socket)
      when is_map(services) do
    {:noreply, assign(socket, :services, %{gateway: services["gateway"] == "on"})}
  end

  def handle_event("services-change", _params, socket), do: {:noreply, socket}

  # --- Reads -----------------------------------------------------------------

  # The mount's starting point: the seeded Size rows, cheapest first —
  # the same public read the wizard presets render. Sizes are internal
  # presets now (#440 took the tiers off the page): this list only
  # resolves the default allocation, filtered to sizes the sliders can
  # state so the default is always expressible (the wizard's stance).
  defp sorted_sizes do
    Size
    |> Ash.Query.for_read(:read, %{}, actor: nil)
    |> Ash.Query.sort(:monthly_cents)
    |> Ash.read!()
    |> Enum.filter(&representable_size?/1)
  end

  # The app options' source (#397): the catalog's public browse read,
  # each app loaded with its versions and their recommended sizes; the
  # latest version is the one whose recommendation snaps. Apps with no
  # version carry no recommendation and stay off the list.
  defp chooser_apps do
    App
    |> Ash.Query.for_read(:list, %{}, actor: nil)
    |> Ash.read!()
    |> Ash.load!([app_versions: :recommended_size], actor: nil)
    |> Enum.flat_map(fn app ->
      case latest_version(app) do
        nil -> []
        version -> [%{app: app, version: version}]
      end
    end)
  end

  # The wizard's version sort (string descending) — the same "latest"
  # the version step shows first.
  defp latest_version(app) do
    app.app_versions
    |> Enum.sort_by(& &1.version, :desc)
    |> List.first()
  end

  # `small`'s allocation, falling back to the cheapest size when the
  # slug is absent (an admin edit), and to the ladders' floor when no
  # Size row exists at all (fresh dev/test DB): the sliders need state,
  # and the price stays whatever price_allocation/1 says it is.
  defp initial_resources(sizes) do
    default = Enum.find(sizes, &(&1.slug == @default_size_slug)) || List.first(sizes)

    if default do
      size_resources(default)
    else
      Map.new(AllocationSliders.resource_dimensions(), fn dimension ->
        {dimension.key, List.first(dimension.values)}
      end)
    end
  end

  defp size_resources(size) do
    %{
      "cpu_cores" => decimal_string(size.cpu_cores),
      "memory_mb" => Integer.to_string(size.memory_mb),
      "storage_gb" => Integer.to_string(size.storage_gb)
    }
  end

  # A size the sliders can state (#221's semantics, mirrored per #397 —
  # the wizard's helper is private, the comparison shape is the
  # contract): every dimension's value must name a rung on its ladder.
  defp representable_size?(size) do
    values = size_resources(size)

    Enum.all?(AllocationSliders.resource_dimensions(), fn dimension ->
      values[dimension.key] in dimension.values
    end)
  end

  # The chooser's verdict on a version's recommendation: snap when the
  # sliders can state it, silent no-op otherwise. A nil recommendation
  # has nothing to snap to, and an off-ladder one has no state the
  # sliders can express. Either way the line stays off: a guessed or
  # unstateable amount would be dishonest.
  defp recommendation(recommended) do
    if is_nil(recommended) do
      :noop
    else
      if representable_size?(recommended), do: {:snap, recommended}, else: :noop
    end
  end

  # The filter reads name and slug, case-insensitively — the two things
  # a visitor types. The selected app's own row stays in the list, so
  # reopening the field shows where the choice sits.
  defp filtered_apps(apps, filter) do
    trimmed = String.trim(filter)
    needle = String.downcase(trimmed)

    Enum.filter(apps, fn chooser ->
      String.contains?(String.downcase(chooser.app.name), needle) or
        String.contains?(String.downcase(chooser.app.slug), needle)
    end)
  end

  # Whether the sliders still hold the recommended allocation. Any rung
  # change makes "Use recommended" useful; the comparison is the same
  # string map the snap wrote.
  defp at_recommendation?(resources, size), do: resources == size_resources(size)

  # Selecting an app: the choice sticks (name, logo, closed panel) and
  # the sliders take the recommendation when they can state it. A nil
  # or off-ladder recommendation selects with no line and no snap —
  # the rungs stay wherever the visitor left them.
  defp select_app(socket, chooser) do
    selected =
      socket
      |> assign(:app_slug, chooser.app.slug)
      |> assign(:app_name, chooser.app.name)
      |> assign(:app_icon_url, chooser.app.icon_url)
      |> assign(:app_filter, "")
      |> assign(:app_picked, true)

    case recommendation(chooser.version.recommended_size) do
      {:snap, size} ->
        selected
        |> assign(:recommendation, size)
        |> assign(:resources, size_resources(size))

      :noop ->
        assign(selected, :recommendation, nil)
    end
  end

  defp clear_selection(socket) do
    assign(socket,
      app_slug: nil,
      app_name: nil,
      app_icon_url: nil,
      recommendation: nil,
      app_filter: "",
      app_picked: false
    )
  end

  # --- Pricing -------------------------------------------------------------------

  # The typed allocation for pricing — total by construction: the state
  # only ever holds rungs (or a whole size allocation, itself a set of
  # rungs), and rungs parse.
  defp allocation(resources) do
    %{
      cpu_cores: Decimal.new(resources["cpu_cores"]),
      memory_mb: String.to_integer(resources["memory_mb"]),
      storage_gb: String.to_integer(resources["storage_gb"])
    }
  end

  # The one pricing call (ADR-0028): shown price = charged price, by
  # construction. Called per row too — price_allocation/1 is pure
  # arithmetic over the allocation, so rows price independently and the
  # sum cannot drift from the parts.
  defp pricing(resources) do
    typed = allocation(resources)
    Pricing.price_allocation(typed)
  end

  # The committed rows' aggregate: each row prices through the same
  # price_allocation/1 call as the live configuration, and the hero
  # adds the parts (never a re-derived whole, which is what would let
  # the shown total drift from the row prices shown beside it).
  defp estimate_cents(estimate) do
    priced = Enum.map(estimate, &pricing(&1.resources))

    %{
      monthly: Enum.sum_by(priced, & &1.monthly_cents),
      stopped: Enum.sum_by(priced, & &1.stopped_monthly_cents)
    }
  end

  # The toggle's exact add: the gateway contributes its accessor cents
  # once per organization whatever the row count, no literals and no
  # estimates. Custom domains are not estimated here at all (ADR-0040
  # Amendment 2): free means there is no calculator line for them.
  defp enabled_service_cents(assigns) do
    if assigns.services.gateway, do: assigns.gateway_monthly_cents, else: 0
  end

  # --- Formatting ----------------------------------------------------------------

  defp size_text(size), do: allocation_text(size_resources(size))

  defp allocation_text(resources) do
    "#{resources["cpu_cores"]} CPU · #{resources["memory_mb"]} MB · #{resources["storage_gb"]} GB"
  end

  # A Decimal as a rung string: normalized first (so 0.50, 1.0 and 1 are
  # one number — the ladder strings are shortest form, and the slider
  # and snap membership checks are string comparisons), then expanded
  # (`:normal` undoes the exponent form normalize lowers to).
  defp decimal_string(value) do
    normalized = Decimal.normalize(value)
    Decimal.to_string(normalized, :normal)
  end
end
