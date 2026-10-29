defmodule FluxValeWeb.CatalogLive.Index do
  @moduledoc """
  Catalog browse (#74): categories with their apps — the deploy flow's
  front door. Reads run through resource policies (any signed-in actor
  browses; public read relaxes with M7 pages).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.Category
  alias FluxVale.Observability.WakeStats

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    categories =
      Category
      |> Ash.Query.for_read(:read, %{}, actor: socket.assigns.current_user)
      |> Ash.Query.sort(:name)
      |> Ash.Query.load(:apps)
      |> Ash.read!()

    {:ok, assign(socket, categories: categories, wake_estimates: safe_wake_estimates())}
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
    >
      <div class="space-y-10">
        <.header>
          Catalog
          <:subtitle>One click from browse to a running instance.</:subtitle>
        </.header>

        <.empty_state :if={@categories == []} title="No apps in the catalog yet." />

        <%!-- Card grid (#277 T4) — see
        catalog_html/index.html.heex for the auto-fill rationale and
        the dark/reduced-motion hover-cue note; the T7 lift split
        (shadow on the link, translate on the wrapper) is noted there
        too. --%>
        <section
          :for={category <- @categories}
          id={"category-#{category.id}"}
          class="space-y-4"
        >
          <div class="space-y-1">
            <h2 class="text-lg font-semibold tracking-tight text-ink">{category.name}</h2>
            <p :if={category.description} class="text-sm text-ink-muted">{category.description}</p>
          </div>

          <div class="grid gap-4 [grid-template-columns:repeat(auto-fill,minmax(min(17rem,100%),1fr))]">
            <.link
              :for={app <- sort_by_name(category.apps)}
              navigate={~p"/apps/#{app.slug}"}
              id={"app-#{app.id}"}
              data-testid={"app-#{app.slug}"}
              class="group block rounded-panel border border-line-strong bg-panel p-5 shadow-sm outline-offset-2 outline-focus focus-visible:outline-2 transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md"
            >
              <div class="transition-[translate] duration-(--motion-base) ease-(--motion-ease-out) motion-safe:group-hover:-translate-y-1">
                <div class="flex items-center gap-3">
                  <%!-- Icon-in-tile (#277 T4): the landing hero's tile idiom —
                  apps with and without an icon share one silhouette. --%>
                  <div class="grid size-9 shrink-0 place-items-center rounded-control bg-primary-muted text-sm font-semibold text-link">
                    <img
                      :if={app.icon_url}
                      src={app.icon_url}
                      alt={app.name}
                      class="size-6 rounded-control"
                    />
                    <span :if={is_nil(app.icon_url)}>{String.first(app.name)}</span>
                  </div>
                  <h3 class="min-w-0 flex-1 text-base font-medium text-ink transition-colors duration-(--motion-fast) [overflow-wrap:anywhere] group-hover:text-link">
                    {app.name}
                  </h3>
                  <.icon
                    name="hero-chevron-right"
                    class="ml-auto size-4 shrink-0 text-ink-subtle opacity-0 transition-opacity duration-(--motion-fast) group-hover:opacity-100"
                  />
                </div>
                <p :if={app.tagline} class="mt-2.5 text-sm text-ink-muted">{app.tagline}</p>
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
        </section>
      </div>
    </Layouts.app>
    """
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
