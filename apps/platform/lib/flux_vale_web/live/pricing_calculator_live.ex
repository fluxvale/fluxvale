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

  The app chooser is a typed filter over real result buttons (app name,
  logo, no-results line) with an explicit Clear. The panel shows while
  focus is inside the field group, so Tab and Enter work natively: no
  ARIA combobox we would have to fake, no JS hook. Selecting an app
  snaps the sliders to its latest version's recommended size when the
  sliders can state it, and the recommendation line names the app and
  the amount. A nil or off-ladder recommendation is a no-op (no snap,
  no line). After a manual edit the line stays and offers "Use
  recommended", which restores the snapped allocation.

  Quantity prices N instances: the curve is per instance, so the hero
  total multiplies it, while the org-level services (the gateway and
  custom domains) bill once. The allocation line says "per instance",
  and the quantity block states the assumption.

  Other services ride inside the calculator as toggles: the gateway
  adds its exact flat rate from the accessor to the displayed total,
  and each toggle's line item shows its own price. Custom domains are
  free (ADR-0040 Amendment 2) and only state the topped-up account
  requirement. The sliders are
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

  # The quantity ladder. The ceiling is a display guard, not a product
  # limit: a visitor comparing a handful of instances never needs more,
  # and the stepper's disabled arms keep the state positive.
  @min_quantity 1
  @max_quantity 20

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # No live_session carries the locale hook for a controller-embedded
    # child, so mount re-resolves it from the session the embed rode —
    # the same resolver the :authenticated live_session's first on_mount
    # runs (Locale's moduledoc: one resolver per render path).
    Gettext.put_locale(FluxValeWeb.Gettext, Locale.resolve(session))

    sizes = sorted_sizes()

    socket =
      socket
      |> assign(:sizes, sizes)
      |> assign(:apps, chooser_apps())
      |> assign(:resources, initial_resources(sizes))
      |> assign(:app_slug, nil)
      |> assign(:app_name, nil)
      |> assign(:recommendation, nil)
      |> assign(:app_filter, "")
      |> assign(:app_picked, false)
      |> assign(:quantity, @min_quantity)
      |> assign(:min_quantity, @min_quantity)
      |> assign(:max_quantity, @max_quantity)
      |> assign(:services, %{gateway: false, domain: false})
      |> assign(:gateway_monthly_cents, AccessGateway.monthly_cents())

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # The totals derive here so no render can disagree with the state:
    # the curve is per instance, so quantity multiplies it, while the
    # enabled services serve the whole organization and bill once. The
    # gateway settles continuously regardless of instance state, so the
    # stopped line owes it too. Custom domains are free (ADR-0040
    # Amendment 2), so the domain toggle contributes nothing.
    price = pricing(assigns.resources)
    service_cents = enabled_service_cents(assigns)

    assigns =
      assign(assigns,
        price: price,
        filtered_apps: filtered_apps(assigns.apps, assigns.app_filter),
        total_cents: assigns.quantity * price.monthly_cents + service_cents,
        stopped_cents: assigns.quantity * price.stopped_monthly_cents + service_cents
      )

    ~H"""
    <div class="space-y-4" data-testid="pricing-calculator">
      <div class="space-y-1">
        <h2 class="text-lg font-semibold tracking-tight text-ink">
          {gettext("Cost calculator")}
        </h2>
        <p class="text-sm text-ink-muted">
          {gettext("Price any allocation with the sliders, or pick an app to start from.")}
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

        <%!-- Quantity: the curve is per instance, so N instances multiply
        it. The services below serve the whole organization and bill
        once, which is the assumption this block states. --%>
        <div
          class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-line px-4 py-3 text-sm"
          data-testid="calculator-quantity-block"
        >
          <div class="space-y-0.5">
            <p class="font-medium text-ink">{gettext("Instances")}</p>
            <p class="text-xs text-ink-subtle">
              {gettext(
                "Every instance gets this allocation. The gateway and custom domain serve the whole organization, so they bill once."
              )}
            </p>
          </div>
          <div class="flex items-center gap-3">
            <button
              type="button"
              id="calculator-quantity-decrease"
              phx-click="quantity-change"
              phx-value-delta="-1"
              disabled={@quantity <= @min_quantity}
              aria-label={gettext("One fewer instance")}
              class="grid size-8 place-items-center rounded-lg border border-line bg-panel text-base text-ink transition-colors outline-offset-2 outline-focus hover:border-line-strong hover:bg-panel-raised focus-visible:outline-2 disabled:cursor-not-allowed disabled:opacity-40"
            >
              −
            </button>
            <span
              class="min-w-8 text-center font-mono text-ink"
              data-testid="calculator-quantity"
              aria-live="polite"
            >
              {@quantity}
            </span>
            <button
              type="button"
              id="calculator-quantity-increase"
              phx-click="quantity-change"
              phx-value-delta="1"
              disabled={@quantity >= @max_quantity}
              aria-label={gettext("One more instance")}
              class="grid size-8 place-items-center rounded-lg border border-line bg-panel text-base text-ink transition-colors outline-offset-2 outline-focus hover:border-line-strong hover:bg-panel-raised focus-visible:outline-2 disabled:cursor-not-allowed disabled:opacity-40"
            >
              +
            </button>
          </div>
        </div>

        <div class="space-y-2">
          <p class="text-sm font-medium text-ink">{gettext("Other services")}</p>
          <%!-- Each toggle's line item shows its own flat price; enabling
          the gateway adds exactly those accessor cents to the total below.
          Custom domains are free, so that toggle adds nothing. --%>
          <form id="calculator-services-form" phx-change="services-change" class="space-y-2">
            <%!-- Always-serialized marker: a form whose checkboxes are all
            unchecked serializes no services keys at all, so unchecking the
            last box would arrive as silence and freeze the stale total.
            The marker guarantees a services param exists, and each service
            is then on exactly when its own key says "on". --%>
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
                  "Private access to your apps without public exposure. One gateway serves every app in your organization and bills once, hourly. Set it up in Settings → Access."
                )}
              </p>
            </div>
            <div
              class="rounded-xl border border-line bg-panel px-4 py-3 text-sm"
              data-testid="service-toggle-domain"
            >
              <label class="flex items-center justify-between gap-3">
                <span class="flex items-center gap-3">
                  <input
                    type="checkbox"
                    name="services[domain]"
                    value="on"
                    checked={@services.domain}
                    class="h-4 w-4 accent-primary"
                  />
                  <span class="min-w-0">
                    <span class="block font-medium text-ink">{gettext("Custom domain")}</span>
                    <span class="block text-xs text-ink-subtle">
                      {gettext(
                        "Serve your apps under your own domain name. Free on topped-up accounts."
                      )}
                    </span>
                  </span>
                </span>
                <span class="font-medium text-ink">{gettext("Free")}</span>
              </label>
            </div>
          </form>
          <p class="text-xs text-ink-subtle">
            {gettext("Hostnames under fluxvale.app, public exposure, DNS, and resolution are free.")}
          </p>
        </div>

        <%!-- The hero number (#440): curve + enabled services, prominent,
        announcing updates (the top-up wizard's aria-live pattern). --%>
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
          <span class="font-mono text-ink-muted" data-testid="calculator-allocation">
            {allocation_line(@quantity, @resources)}
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
  # recommended size when the sliders can state it, and remembers the
  # recommendation so the line survives manual edits. A nil or
  # off-ladder recommendation is a no-op: no snap, no line, no guessed
  # amount. The choice is a start-from picker, not a promise about the
  # rungs, so the selection stays after a snap while the sliders move.
  @impl Phoenix.LiveView
  def handle_event("pick-app", %{"slug" => slug}, socket) when is_binary(slug) do
    case Enum.find(socket.assigns.apps, &(&1.app.slug == slug)) do
      nil ->
        {:noreply, socket}

      chooser ->
        case recommendation(chooser.version.recommended_size) do
          {:snap, size} ->
            {:noreply,
             socket
             |> assign(:app_slug, slug)
             |> assign(:app_name, chooser.app.name)
             |> assign(:recommendation, size)
             |> assign(:resources, size_resources(size))
             |> assign(:app_filter, "")
             |> assign(:app_picked, true)}

          :noop ->
            {:noreply, clear_selection(socket)}
        end
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

  # The quantity stepper. Only the two rendered deltas move the count,
  # and both bounds clamp, so a crafted payload can never drive it to
  # zero or past the ceiling.
  def handle_event("quantity-change", %{"delta" => delta}, socket) when delta in ["-1", "1"] do
    step = String.to_integer(delta)
    quantity = min(max(socket.assigns.quantity + step, @min_quantity), @max_quantity)

    {:noreply, assign(socket, :quantity, quantity)}
  end

  def handle_event("quantity-change", _params, socket), do: {:noreply, socket}

  # The explicit Clear: deselects the app, forgets its recommendation,
  # empties the filter, and leaves the rungs wherever the visitor put
  # them.
  def handle_event("clear-app", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  # Service toggles: a checkbox change serializes only the checked
  # boxes, so each service is on exactly when its key arrives. A crafted
  # payload whose services value is not a map decodes to nothing.
  def handle_event("services-change", %{"services" => services}, socket)
      when is_map(services) do
    {:noreply,
     assign(socket, :services, %{
       gateway: services["gateway"] == "on",
       domain: services["domain"] == "on"
     })}
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

  defp clear_selection(socket) do
    assign(socket,
      app_slug: nil,
      app_name: nil,
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
  # construction.
  defp pricing(resources) do
    typed = allocation(resources)
    Pricing.price_allocation(typed)
  end

  # The toggles' exact add: the gateway contributes its accessor cents,
  # no literals and no estimates. Custom domains are free (ADR-0040
  # Amendment 2), so the domain toggle adds nothing.
  defp enabled_service_cents(assigns) do
    if assigns.services.gateway, do: assigns.gateway_monthly_cents, else: 0
  end

  # --- Formatting ----------------------------------------------------------------

  # One instance's allocation, and the quantity when it is above one:
  # "3 × 0.5 CPU · 512 MB · 10 GB per instance". The "per instance"
  # suffix is always there, so the hero never reads as a whole-fleet
  # allocation by accident.
  defp allocation_line(quantity, resources) do
    suffix = allocation_text(resources) <> " per instance"

    if quantity == 1, do: suffix, else: "#{quantity} × #{suffix}"
  end

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
