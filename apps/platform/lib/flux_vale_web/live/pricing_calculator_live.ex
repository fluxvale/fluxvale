defmodule FluxValeWeb.PricingCalculatorLive do
  @moduledoc """
  The /pricing calculator (#397): the shared allocation sliders plus an
  app chooser from the catalog, priced live through
  FluxVale.Pricing.price_allocation/1 — the same call the ledger prices
  custom allocations through, so the shown price is the charged price by
  construction. The running rate renders via `format_monthly_rate/1` and
  the stopped rate via `format_usd/1` plus " while stopped", the same
  labels the page's rate table carries.

  The /pricing controller page embeds this view with `live_render` (the
  PageController → DashboardLive precedent), so the initial render is
  SSR and crawlers see a formed calculator state. Anonymous-OK like its
  host page: reads ride the public read policies with no actor, and the
  session the embed rode is used only to re-resolve the locale — this
  view sits in no live_session, so no on_mount carries the hook.

  Size quick-pick chips are the seeded Sizes the sliders can state,
  cheapest first — an admin-edited off-ladder size gets no chip, a pick
  the surface cannot express being worse than no pick (the wizard's
  stance). The chooser snaps to the app's latest version's recommended
  size when representable, shows the recommended rate as a static line
  when it is off-ladder, and renders no line at all when the version
  carries no recommendation (the column is deliberately nullable,
  pre-#125).

  The sliders are FluxValeWeb.AllocationSliders verbatim (the deploy
  wizard's component); its DOM ids are page-unique by contract, and the
  wizard is a different page, so the calculator reuses them as-is.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.App
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

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # The chips carry their own pressed state — `aria-pressed` is a
    # string attribute (the wizard's pattern, a bare boolean renders as
    # an empty value and announces nothing). The price derives from the
    # rungs here so no render can disagree with the state.
    assigns =
      assign(assigns,
        price: pricing(assigns.resources),
        size_chips: size_chips(assigns),
        app_chips: app_chips(assigns),
        app_view: app_view(assigns)
      )

    ~H"""
    <div class="space-y-4" data-testid="pricing-calculator">
      <div class="space-y-1">
        <h2 class="text-lg font-semibold tracking-tight text-ink">
          {gettext("Cost calculator")}
        </h2>
        <p class="text-sm text-ink-muted">
          {gettext("Price any allocation with the sliders, or snap to a size or an app below.")}
        </p>
      </div>

      <.card class="space-y-6">
        <div class="space-y-2">
          <p class="text-sm font-medium text-ink" id="calculator-sizes-label">
            {gettext("Sizes")}
          </p>
          <div class="flex flex-wrap gap-2" role="group" aria-labelledby="calculator-sizes-label">
            <button
              :for={chip <- @size_chips}
              type="button"
              id={"size-chip-#{chip.slug}"}
              phx-click="pick-size"
              phx-value-slug={chip.slug}
              aria-pressed={chip.pressed}
              data-testid={"size-chip-#{chip.slug}"}
              class={[
                "rounded-lg border px-3 py-1.5 transition-colors",
                "outline-offset-2 outline-focus focus-visible:outline-2",
                if(chip.pressed == "true",
                  do: "border-primary bg-primary-muted",
                  else: "border-line bg-panel hover:border-line-strong hover:bg-panel-raised"
                )
              ]}
            >
              <span class="text-sm font-medium text-ink capitalize">{chip.slug}</span>
              <span class="ml-2 font-mono text-xs text-ink-muted">{chip.allocation}</span>
            </button>
          </div>
        </div>

        <div class="space-y-2">
          <p class="text-sm font-medium text-ink" id="calculator-apps-label">
            {gettext("Pick an app")}
          </p>
          <div class="flex flex-wrap gap-2" role="group" aria-labelledby="calculator-apps-label">
            <button
              :for={chip <- @app_chips}
              type="button"
              id={"app-chip-#{chip.slug}"}
              phx-click="pick-app"
              phx-value-slug={chip.slug}
              aria-pressed={chip.pressed}
              data-testid={"app-chip-#{chip.slug}"}
              class={[
                "rounded-lg border px-3 py-1.5 transition-colors",
                "outline-offset-2 outline-focus focus-visible:outline-2",
                if(chip.pressed == "true",
                  do: "border-primary bg-primary-muted",
                  else: "border-line bg-panel hover:border-line-strong hover:bg-panel-raised"
                )
              ]}
            >
              {chip.name}
            </button>
          </div>
          <p class="text-xs text-ink-subtle">
            {gettext("The price depends only on the allocation, never the app.")}
          </p>
        </div>

        <div
          :if={@app_view}
          class="rounded-xl bg-panel-raised px-4 py-3 text-sm"
          data-testid="calculator-app-recommendation"
        >
          <p :if={@app_view.snap} class="text-ink">
            {gettext("%{app} recommends", app: @app_view.app.name)}
            <span class="font-mono text-ink">{@app_view.allocation}</span>
          </p>
          <p :if={not @app_view.snap} class="text-ink">
            {gettext(
              "%{app} recommends a size these sliders don't cover. That size prices at %{rate}.",
              app: @app_view.app.name,
              rate: Pricing.format_monthly_rate(@app_view.monthly_cents)
            )}
          </p>
        </div>

        <form id="calculator-resources-form" phx-change="resources-change">
          <AllocationSliders.sliders resources={@resources} />
        </form>

        <div
          class="flex flex-wrap items-center justify-between gap-4 rounded-xl bg-panel-raised px-4 py-3 text-sm"
          data-testid="calculator-price"
        >
          <span class="font-mono text-ink-muted" data-testid="calculator-allocation">
            {allocation_text(@resources)}
          </span>
          <span class="text-right" aria-live="polite">
            <span
              class="block text-base font-semibold text-ink"
              data-testid="calculator-price-running"
            >
              {Pricing.format_monthly_rate(@price.monthly_cents)}
            </span>
            <span class="block text-ink-muted" data-testid="calculator-price-stopped">
              {gettext(
                "%{rate}/mo while stopped",
                rate: Pricing.format_usd(@price.stopped_monthly_cents)
              )}
            </span>
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

  # A size quick pick: the size's whole allocation at once — the same
  # state a slider round trip would reach, priced through the same
  # price_allocation/1 call.
  def handle_event("pick-size", %{"slug" => slug}, socket) do
    case Enum.find(socket.assigns.sizes, &(&1.slug == slug)) do
      nil ->
        # A crafted slug (or a size filtered off the chips): the rendered
        # buttons can't produce one. Nothing to read, nothing changes.
        {:noreply, socket}

      size ->
        {:noreply, assign(socket, :resources, size_resources(size))}
    end
  end

  # The app chooser: snap to the app's latest version's recommended size
  # when the sliders can state it. When they can't, the sliders stay put
  # and the render shows the recommended rate as a static line — a snap
  # the sliders can't express would lie about what they set. A version
  # with no recommendation at all is a silent no-op.
  def handle_event("pick-app", %{"slug" => slug}, socket) do
    case Enum.find(socket.assigns.apps, &(&1.app.slug == slug)) do
      nil ->
        {:noreply, socket}

      chooser ->
        case recommendation(chooser.version.recommended_size) do
          {:snap, size} ->
            {:noreply,
             socket
             |> assign(:app_slug, slug)
             |> assign(:resources, size_resources(size))}

          {:static, _size} ->
            {:noreply, assign(socket, :app_slug, slug)}

          :none ->
            {:noreply, socket}
        end
    end
  end

  # --- Reads -----------------------------------------------------------------

  # The size chips' source (#397): the seeded Size rows, cheapest first
  # — the same public read the page's rate table renders. The chips and
  # the pick-size lookup share this one list, filtered to sizes the
  # sliders can state: an off-ladder size gets no chip — a pick the
  # surface cannot express is worse than no pick (the wizard's stance) —
  # and a crafted slug naming one is silence.
  defp sorted_sizes do
    Size
    |> Ash.Query.for_read(:read, %{}, actor: nil)
    |> Ash.Query.sort(:monthly_cents)
    |> Ash.read!()
    |> Enum.filter(&representable_size?/1)
  end

  # The app chips' source (#397): the catalog's public browse read, each
  # app loaded with its versions and their recommended sizes; the latest
  # version is the one whose recommendation snaps. Apps with no version
  # carry no recommendation and stay off the list.
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
  # sliders can state it, a static rate line when they can't, and no
  # line at all when the version carries no recommendation — the column
  # is deliberately nullable (pre-#125 rows heal via seed convergence),
  # and a nil recommendation has no rate to show either. One classifier
  # for the event and the render, so the two cannot disagree.
  defp recommendation(recommended) do
    cond do
      is_nil(recommended) -> :none
      representable_size?(recommended) -> {:snap, recommended}
      true -> {:static, recommended}
    end
  end

  # --- Render derives ----------------------------------------------------------

  defp size_chips(assigns) do
    for size <- assigns.sizes do
      %{
        slug: size.slug,
        allocation: size_allocation(size),
        pressed: to_string(size_active?(assigns.resources, size))
      }
    end
  end

  # A size reads as pressed only when the allocation IS the size — the
  # wizard's preset_active? comparison, so a repriced or re-allocated
  # row degrades to "nothing pressed" instead of lying.
  defp size_active?(resources, size) do
    current = allocation(resources)

    Decimal.eq?(current.cpu_cores, size.cpu_cores) and
      current.memory_mb == size.memory_mb and
      current.storage_gb == size.storage_gb
  end

  defp app_chips(assigns) do
    for chooser <- assigns.apps do
      %{
        slug: chooser.app.slug,
        name: chooser.app.name,
        pressed: to_string(assigns.app_slug == chooser.app.slug)
      }
    end
  end

  defp app_view(assigns) do
    case Enum.find(assigns.apps, &(&1.app.slug == assigns.app_slug)) do
      nil -> nil
      chooser -> recommendation_view(chooser)
    end
  end

  defp recommendation_view(chooser) do
    case recommendation(chooser.version.recommended_size) do
      {:snap, size} -> %{app: chooser.app, snap: true, allocation: size_allocation(size)}
      {:static, size} -> %{app: chooser.app, snap: false, monthly_cents: size.monthly_cents}
      # pick-app's :none arm is a full no-op (app_slug stays unset), so
      # this verdict cannot reach the render; the clause keeps the
      # classifier's total honored here too — no line, never a crash.
      # coveralls-ignore-next-line — defensive: unreachable while the no-op contract holds
      :none -> nil
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

  # --- Formatting ----------------------------------------------------------------

  defp size_allocation(size) do
    "#{decimal_string(size.cpu_cores)} CPU · #{size.memory_mb} MB · #{size.storage_gb} GB"
  end

  defp allocation_text(resources) do
    "#{resources["cpu_cores"]} CPU · #{resources["memory_mb"]} MB · #{resources["storage_gb"]} GB"
  end

  # A Decimal as a rung string: normalized first (so 0.50, 1.0 and 1 are
  # one number — the ladder strings are shortest form, and the chip
  # membership check is a string comparison), then expanded
  # (`:normal` undoes the exponent form normalize lowers to).
  defp decimal_string(value) do
    normalized = Decimal.normalize(value)
    Decimal.to_string(normalized, :normal)
  end
end
