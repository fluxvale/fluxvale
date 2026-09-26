defmodule FluxValeWeb.CatalogLive.Index do
  @moduledoc """
  Catalog browse (#74): categories with their apps — the deploy flow's
  front door. Reads run through resource policies (any signed-in actor
  browses; public read relaxes with M7 pages).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.Category

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    categories =
      Category
      |> Ash.Query.for_read(:read, %{}, actor: socket.assigns.current_user)
      |> Ash.Query.sort(:name)
      |> Ash.Query.load(:apps)
      |> Ash.read!()

    {:ok, assign(socket, :categories, categories)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-10">
        <div class="space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">Catalog</h1>
          <p class="text-sm opacity-70">One click from browse to a running instance.</p>
        </div>

        <div :if={@categories == []} class="card bg-base-200">
          <div class="card-body items-center text-center py-12">
            <p class="opacity-70">No apps in the catalog yet.</p>
          </div>
        </div>

        <section
          :for={category <- @categories}
          id={"category-#{category.id}"}
          class="space-y-4"
        >
          <div class="space-y-1">
            <h2 class="text-xl font-semibold">{category.name}</h2>
            <p :if={category.description} class="text-sm opacity-70">{category.description}</p>
          </div>

          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <.link
              :for={app <- sort_by_name(category.apps)}
              navigate={~p"/apps/#{app.slug}"}
              id={"app-#{app.id}"}
              class="card bg-base-200 hover:bg-base-300 transition-colors"
            >
              <div class="card-body gap-2 py-4">
                <div class="flex items-center gap-3">
                  <div class="size-8 rounded bg-primary/15 text-primary flex items-center justify-center font-semibold">
                    <img :if={app.icon_url} src={app.icon_url} alt={app.name} class="size-8 rounded" />
                    <span :if={is_nil(app.icon_url)}>{String.first(app.name)}</span>
                  </div>
                  <h3 class="card-title text-base">{app.name}</h3>
                </div>
                <p :if={app.tagline} class="text-sm opacity-70">{app.tagline}</p>
              </div>
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp sort_by_name(apps), do: Enum.sort_by(apps, & &1.name)
end
