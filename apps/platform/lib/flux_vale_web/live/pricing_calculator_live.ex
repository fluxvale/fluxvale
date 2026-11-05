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

  The app chooser is a native select (type-ahead at the current catalog
  size, a filtered listbox deferred until the catalog grows past ~15
  apps) with an explicit Clear. Selecting an app snaps the sliders to
  its latest version's recommended size when the sliders can state it;
  a nil or off-ladder recommendation is a no-op (no snap, no line —
  #440 removed the static-rate arm along with the tiers).

  Other services ride inside the calculator as toggles: enabling one
  adds its exact flat rate from the accessors to the displayed total,
  and each toggle's line item shows its own price. The sliders are
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
  alias FluxVale.Infrastructure.AccessDomain
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

    socket =
      socket
      |> assign(:sizes, sizes)
      |> assign(:apps, chooser_apps())
      |> assign(:resources, initial_resources(sizes))
      |> assign(:app_slug, nil)
      |> assign(:services, %{gateway: false, domain: false})
      |> assign(:gateway_monthly_cents, AccessGateway.monthly_cents())
      |> assign(:domain_monthly_cents, AccessDomain.monthly_cents())

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # The totals derive here so no render can disagree with the state:
    # the curve part prices the rungs, and each enabled toggle adds its
    # exact accessor cents to both figures — gateway and domain settle
    # continuously regardless of instance state, so the stopped line
    # owes them too.
    price = pricing(assigns.resources)

    assigns =
      assign(assigns,
        price: price,
        total_cents: price.monthly_cents + enabled_service_cents(assigns),
        stopped_cents: price.stopped_monthly_cents + enabled_service_cents(assigns)
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
          <div class="flex items-center gap-2">
            <%!-- Native select: type-ahead search for free at the current
            catalog size (#440), a filtered listbox deferred until the
            catalog grows past ~15 apps. --%>
            <form id="calculator-app-form" phx-change="pick-app" class="flex-1">
              <select
                id="calculator-app-select"
                name="app_slug"
                aria-labelledby="calculator-apps-label"
                class="w-full rounded-lg border border-line bg-panel px-3 py-2 text-sm text-ink outline-offset-2 outline-focus focus-visible:border-line-strong focus-visible:outline-2"
              >
                <option value="" selected={is_nil(@app_slug)}>{gettext("Choose an app")}</option>
                <option
                  :for={chooser <- @apps}
                  value={chooser.app.slug}
                  selected={@app_slug == chooser.app.slug}
                >
                  {chooser.app.name}
                </option>
              </select>
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
          <p class="text-xs text-ink-subtle">
            {gettext("The price depends only on the allocation, never the app.")}
          </p>
        </div>

        <form id="calculator-resources-form" phx-change="resources-change">
          <AllocationSliders.sliders resources={@resources} />
        </form>

        <div class="space-y-2">
          <p class="text-sm font-medium text-ink">{gettext("Other services")}</p>
          <%!-- Each toggle's line item shows its own flat price; enabling
          one adds exactly those accessor cents to the total below. --%>
          <form id="calculator-services-form" phx-change="services-change" class="space-y-2">
            <%!-- Always-serialized marker: a form whose checkboxes are all
            unchecked serializes no services keys at all, so unchecking the
            last box would arrive as silence and freeze the stale total.
            The marker guarantees a services param exists, and each service
            is then on exactly when its own key says "on". --%>
            <input type="hidden" name="services[_marker]" value="1" />
            <label
              class="flex items-center justify-between gap-3 rounded-xl border border-line bg-panel px-4 py-3 text-sm transition-colors hover:border-line-strong"
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
                <span class="min-w-0">
                  <span class="block font-medium text-ink">{gettext("Private access gateway")}</span>
                  <span class="block text-xs text-ink-subtle">
                    {gettext("One gateway serves every app in your organization")}
                  </span>
                </span>
              </span>
              <span class="font-medium text-ink">
                {gettext(
                  "+%{rate}/mo per gateway, billed hourly",
                  rate: Pricing.format_usd(@gateway_monthly_cents)
                )}
              </span>
            </label>
            <label
              class="flex items-center justify-between gap-3 rounded-xl border border-line bg-panel px-4 py-3 text-sm transition-colors hover:border-line-strong"
              data-testid="service-toggle-domain"
            >
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
                    {gettext("Serve your apps under your own domain name")}
                  </span>
                </span>
              </span>
              <span class="font-medium text-ink">
                {gettext(
                  "+%{rate}/mo per verified domain, billed hourly",
                  rate: Pricing.format_usd(@domain_monthly_cents)
                )}
              </span>
            </label>
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

  # The app chooser: a select change snaps the sliders to the latest
  # version's recommended size when the sliders can state it. Anything
  # else (a nil recommendation, an off-ladder one, a crafted slug) is a
  # no-op: the sliders stay put and the select falls back to the prompt.
  # The select is a start-from picker, not a promise about the rungs —
  # after a snap the sliders can move freely while the selection stays.
  # The empty value is the prompt option — a clear by way of the select
  # itself.
  @impl Phoenix.LiveView
  def handle_event("pick-app", %{"app_slug" => ""}, socket) do
    {:noreply, assign(socket, :app_slug, nil)}
  end

  def handle_event("pick-app", %{"app_slug" => slug}, socket) when is_binary(slug) do
    case Enum.find(socket.assigns.apps, &(&1.app.slug == slug)) do
      nil ->
        {:noreply, assign(socket, :app_slug, nil)}

      chooser ->
        case recommendation(chooser.version.recommended_size) do
          {:snap, size} ->
            {:noreply,
             socket
             |> assign(:app_slug, slug)
             |> assign(:resources, size_resources(size))}

          :noop ->
            {:noreply, assign(socket, :app_slug, nil)}
        end
    end
  end

  # A crafted payload whose app_slug value is not a string decodes to
  # nothing — silence, like any unmatched shape.
  def handle_event("pick-app", _params, socket), do: {:noreply, socket}

  # The explicit Clear (#440): deselects the app, leaves the rungs
  # wherever the visitor put them.
  def handle_event("clear-app", _params, socket) do
    {:noreply, assign(socket, :app_slug, nil)}
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

  # The chooser's verdict on a version's recommendation (#440): snap
  # when the sliders can state it, silent no-op otherwise — a nil
  # recommendation has nothing to snap to, and an off-ladder one has no
  # state the sliders can express (the #397 static-rate arm died with
  # the tiers; a line naming a size the page no longer shows would
  # market tiers).
  defp recommendation(recommended) do
    if is_nil(recommended) do
      :noop
    else
      if representable_size?(recommended), do: {:snap, recommended}, else: :noop
    end
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

  # The toggles' exact add: each enabled service contributes its own
  # accessor cents — no literals, no estimates.
  defp enabled_service_cents(assigns) do
    gateway = if assigns.services.gateway, do: assigns.gateway_monthly_cents, else: 0
    domain = if assigns.services.domain, do: assigns.domain_monthly_cents, else: 0

    gateway + domain
  end

  # --- Formatting ----------------------------------------------------------------

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
