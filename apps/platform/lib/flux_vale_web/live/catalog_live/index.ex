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

    {:ok, assign(socket, categories: categories, wake_estimates: WakeStats.median_total_by_app())}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-10">
        <.header>
          Catalog
          <:subtitle>One click from browse to a running instance.</:subtitle>
        </.header>

        <.empty_state :if={@categories == []} title="No apps in the catalog yet." />

        <section
          :for={category <- @categories}
          id={"category-#{category.id}"}
          class="space-y-4"
        >
          <div class="space-y-1">
            <h2 class="text-lg font-semibold tracking-tight text-ink">{category.name}</h2>
            <p :if={category.description} class="text-sm text-ink-muted">{category.description}</p>
          </div>

          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <.link
              :for={app <- sort_by_name(category.apps)}
              navigate={~p"/apps/#{app.slug}"}
              id={"app-#{app.id}"}
              data-testid={"app-#{app.slug}"}
              class="group relative rounded-xl border border-line bg-panel p-5 shadow-sm transition-all hover:border-primary/40 hover:shadow-md"
            >
              <div class="flex items-center gap-3">
                <div class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary-muted font-semibold text-primary">
                  <img :if={app.icon_url} src={app.icon_url} alt={app.name} class="size-9 rounded-lg" />
                  <span :if={is_nil(app.icon_url)}>{String.first(app.name)}</span>
                </div>
                <h3 class="text-base font-medium text-ink transition-colors group-hover:text-primary">
                  {app.name}
                </h3>
                <.icon
                  name="hero-chevron-right"
                  class="ml-auto size-4 text-ink-subtle opacity-0 transition-opacity group-hover:opacity-100"
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
