defmodule FluxValeWeb.CatalogLive.Show do
  @moduledoc """
  App detail (#74): blueprint summary, versions, and the deploy stepper's
  entry. Slug-keyed read through `Catalog.App.get_by_slug/2`.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Catalog.App.get_by_slug(slug, actor: user) do
      {:ok, app} ->
        app = Ash.load!(app, [:app_versions, :category], actor: user)
        {:ok, assign(socket, app: app, versions: sorted_desc(app.app_versions))}

      _error ->
        # Unknown slugs (and policy denials) read as "not here" — back to
        # the catalog rather than a bare 404.
        {:ok,
         socket
         |> put_flash(:error, "App not found.")
         |> push_navigate(to: ~p"/apps")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/apps"} class="btn btn-ghost btn-sm mb-4">
            &larr; Catalog
          </.link>

          <div class="flex items-start gap-4">
            <div class="size-14 rounded-lg bg-primary/15 text-primary flex items-center justify-center text-xl font-semibold">
              <img :if={@app.icon_url} src={@app.icon_url} alt={@app.name} class="size-14 rounded-lg" />
              <span :if={is_nil(@app.icon_url)}>{String.first(@app.name)}</span>
            </div>
            <div class="space-y-1">
              <h1 class="text-3xl font-bold tracking-tight">{@app.name}</h1>
              <p :if={@app.tagline} class="opacity-70">{@app.tagline}</p>
              <div class="flex gap-3 text-sm">
                <span class="badge badge-ghost badge-sm">{@app.category.name}</span>
                <a
                  :if={@app.source_url}
                  href={@app.source_url}
                  class="link link-hover"
                  target="_blank"
                  rel="noopener"
                >
                  Source
                </a>
                <a
                  :if={@app.docs_url}
                  href={@app.docs_url}
                  class="link link-hover"
                  target="_blank"
                  rel="noopener"
                >
                  Docs
                </a>
              </div>
            </div>
          </div>
        </div>

        <p :if={@app.description} class="whitespace-pre-line leading-relaxed">{@app.description}</p>

        <div class="space-y-4">
          <h2 class="text-xl font-semibold">Versions</h2>

          <div class="space-y-4">
            <div :for={version <- @versions} id={"version-#{version.id}"} class="card bg-base-200">
              <div class="card-body gap-4 py-4">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <h3 class="font-semibold font-mono">v{version.version}</h3>
                    <p :if={version.published_at} class="text-xs opacity-60">
                      Published {Calendar.strftime(version.published_at, "%b %d, %Y")}
                    </p>
                  </div>
                  <.link
                    navigate={~p"/apps/#{@app.slug}/deploy"}
                    class="btn btn-primary btn-sm"
                    id={"deploy-#{version.id}"}
                    data-testid={"deploy-#{version.version}"}
                  >
                    Deploy
                  </.link>
                </div>
                <p :if={version.release_notes} class="whitespace-pre-line text-sm opacity-70">
                  {version.release_notes}
                </p>
                <div class="flex flex-wrap gap-2 text-xs">
                  <span class="badge badge-ghost">{version.default_cpu_cores} CPU</span>
                  <span class="badge badge-ghost">{version.default_memory_mb} MB RAM</span>
                  <span class="badge badge-ghost">{version.default_storage_gb} GB storage</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Lexicographic on the version string — exact while the seed carries
  # one version per app; semver-aware sorting arrives with multi-version
  # apps (a #70-era non-problem, noted here so nobody trusts it early).
  defp sorted_desc(versions), do: Enum.sort_by(versions, & &1.version, :desc)
end
