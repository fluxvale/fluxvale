defmodule FluxValeWeb.CatalogLive.Index do
  @moduledoc """
  Catalog browse (#74): the apps as a dense mosaic — the deploy flow's
  front door. Reads run through resource policies (any signed-in actor
  browses; public read relaxes with M7 pages). The category structure
  rides each card's mono eyebrow (category-then-name order); the old
  per-category sections are gone with the S7 mosaic.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.Category
  alias FluxVale.Observability.WakeStats

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The mosaic renders the flat {app, category} stream only — there is
    # no category assign left to render (hostile-341 F10); the :apps
    # load feeds catalog_apps/1.
    catalog_apps =
      Category
      |> Ash.Query.for_read(:read, %{}, actor: socket.assigns.current_user)
      |> Ash.Query.sort(:name)
      |> Ash.Query.load(:apps)
      |> Ash.read!()
      |> catalog_apps()

    {:ok,
     assign(socket,
       catalog_apps: catalog_apps,
       wake_estimates: safe_wake_estimates()
     )}
  end

  # The badge must never take the catalog down: the named WakeStats
  # server rides the app tree, and a crash-restart gap (or an
  # over-slow scrape walk) would otherwise exit this mount — the
  # quiet card is the honest degradation.
  defp safe_wake_estimates do
    WakeStats.median_total_by_app()
  rescue
    # coveralls-ignore-start - both arms answer {} so the badge can't
    # take the catalog down; the named server is alive under the app
    # tree for the whole suite (a call exits only in the supervisor's
    # restart gap, which no test can hold open).
    _exception ->
      %{}
  catch
    :exit, _reason ->
      %{}
      # coveralls-ignore-stop
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
    >
      <div class="appgram contents">
        <%!-- 1. The sunken band header — same shape as the instances
        index. Copy unchanged; "App catalog" is the landing band's own
        eyebrow label. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">App catalog</p>
              <h1 class="page-title mt-1.5">Catalog</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                One click from browse to a running instance.
              </p>
            </div>
          </div>
        </section>

        <%!-- 2. The mosaic: one grid, all apps. Category sections would
        each leave their row partly empty (the card-dribble tell), so
        the grouping rides each card's mono eyebrow instead — see the
        grid comment below for the self-fitting track rule. Same card
        language as the instance rows: link box stays put, the inner
        wrapper lifts (a bottom-1px click still lands in the link). --%>
        <section class="wrap pt-14 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <.empty_state :if={@catalog_apps == []} title="No apps in the catalog yet." />

            <%!-- Self-fitting mosaic (hostile-341 F1/F2/F3): auto-fit
            collapses unused tracks, so small catalogs fill the wrap (a
            1-app catalog is one full-width card) and grown catalogs get
            3 tracks at desktop; the 17rem floor means 2 tracks only
            when each cell is at least 17rem — no 216px cliff cells. --%>
            <div
              id="catalog-mosaic"
              class="grid grid-cols-[repeat(auto-fit,minmax(min(17rem,100%),1fr))] gap-4"
            >
              <.link
                :for={{app, category} <- @catalog_apps}
                navigate={~p"/apps/#{app.slug}"}
                id={"app-#{app.id}"}
                data-testid={"app-#{app.slug}"}
                class="group relative block rounded-panel border border-line-strong bg-panel p-5 shadow-sm outline-offset-2 outline-focus focus-visible:outline-2 transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md"
              >
                <div class="flex h-full flex-col transition-[translate] duration-(--motion-base) ease-(--motion-ease-out) motion-safe:group-hover:-translate-y-1">
                  <%!-- The landing mini-catalog's cell shape: mono category,
                  then chip + name, then description. Icon-in-tile (#277
                  T4) keeps one silhouette for icon-less apps. The
                  eyebrow can't wrap (nowrap holds the row line), and the
                  tagline holds two lines so stretched cells even out
                  (hostile-341 F3). --%>
                  <p class="eyebrow whitespace-nowrap">{category.name}</p>
                  <div class="relative mt-2 flex items-center gap-3">
                    <div class="grid size-9 shrink-0 place-items-center rounded-control bg-primary-muted text-sm font-semibold text-link">
                      <img
                        :if={app.icon_url}
                        src={app.icon_url}
                        alt={app.name}
                        class="size-6 rounded-control"
                      />
                      <span :if={is_nil(app.icon_url)}>{String.first(app.name)}</span>
                    </div>
                    <h2 class="min-w-0 flex-1 text-base font-medium text-ink transition-colors duration-(--motion-fast) [overflow-wrap:anywhere] group-hover:text-link">
                      {app.name}
                    </h2>
                    <%!-- Out of flow: the affordance holds no layout space
                      at rest — 28px stays with the name at the narrowest
                      cells (hostile-341 F8). --%>
                    <.icon
                      name="hero-chevron-right"
                      class="absolute top-1/2 right-0 size-4 -translate-y-1/2 text-ink-subtle opacity-0 transition-opacity duration-(--motion-fast) group-hover:opacity-100"
                    />
                  </div>
                  <p
                    :if={app.tagline}
                    class="mt-2.5 line-clamp-2 min-h-10 text-sm text-ink-muted"
                  >
                    {app.tagline}
                  </p>
                  <%= if estimate = @wake_estimates[app.slug] do %>
                    <p
                      class="mt-3 text-xs font-medium text-success"
                      data-testid={"wake-estimate-#{app.slug}"}
                    >
                      <.icon name="hero-bolt" class="size-3.5 inline-block align-text-bottom" />
                      Wakes in {format_estimate(estimate)}
                    </p>
                  <% end %>
                </div>
              </.link>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The mosaic's flat stream: {app, category} pairs in the same order
  # the per-category sections read in — categories by name, apps by
  # name within each.
  defp catalog_apps(categories) do
    for category <- categories, app <- sort_by_name(category.apps), do: {app, category}
  end

  defp sort_by_name(apps), do: Enum.sort_by(apps, & &1.name)

  # The badge's copy: an honest ~estimate (median of N wakes, the same
  # series the SLO dashboard charts — WakeStats), rounded to the
  # second; over a minute, minutes-and-seconds reads truer than "74s".
  defp format_estimate(seconds) do
    rounded = round(seconds)

    if rounded < 60 do
      "~#{rounded}s"
    else
      "~#{div(rounded, 60)}m #{rem(rounded, 60)}s"
    end
  end
end
