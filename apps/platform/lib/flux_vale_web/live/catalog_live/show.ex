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
        app = Ash.load!(app, [:category, app_versions: :recommended_size], actor: user)
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
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
    >
      <div class="space-y-8">
        <div>
          <.button variant="ghost" size="sm" navigate={~p"/apps"} class="-ml-2 mb-4">
            &larr; Catalog
          </.button>

          <%!-- App poster (#277 T4): identity + description in one card —
          the page's panel band; versions stay cards on canvas below. --%>
          <.card class="space-y-4">
            <div class="flex items-start gap-4">
              <div class="grid size-14 shrink-0 place-items-center rounded-control bg-primary-muted text-xl font-semibold text-link">
                <img
                  :if={@app.icon_url}
                  src={@app.icon_url}
                  alt={@app.name}
                  class="size-9 rounded-control"
                />
                <span :if={is_nil(@app.icon_url)}>{String.first(@app.name)}</span>
              </div>
              <div class="space-y-1.5">
                <h1 class="text-2xl font-semibold tracking-tight text-ink">{@app.name}</h1>
                <p :if={@app.tagline} class="text-ink-muted">{@app.tagline}</p>
                <div class="flex flex-wrap items-center gap-3 pt-1 text-sm">
                  <.badge>{@app.category.name}</.badge>
                  <.badge :if={@app.file_access} data-testid="file-access-badge">
                    File access
                  </.badge>
                  <a
                    :if={@app.source_url}
                    href={@app.source_url}
                    class="font-medium text-link hover:underline"
                    target="_blank"
                    rel="noopener"
                  >
                    Source
                  </a>
                  <a
                    :if={@app.docs_url}
                    href={@app.docs_url}
                    class="font-medium text-link hover:underline"
                    target="_blank"
                    rel="noopener"
                  >
                    Docs
                  </a>
                </div>
              </div>
            </div>
            <p
              :if={is_binary(@app.description) and String.trim(@app.description) != ""}
              class="border-t border-line pt-4 leading-relaxed text-ink-muted"
            >
              <%!-- pre-line rides the span: the p's own whitespace is normal,
              so the template's indentation newlines collapse instead of
              laying out a phantom blank line (T4 review). --%>
              <span class="whitespace-pre-line">{String.trim(@app.description)}</span>
            </p>
          </.card>
        </div>

        <div class="space-y-4">
          <h2 class="text-lg font-semibold tracking-tight text-ink">Versions</h2>

          <div class="space-y-4">
            <.card :for={version <- @versions} id={"version-#{version.id}"} class="space-y-4">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h3 class="font-mono font-semibold text-ink">v{version.version}</h3>
                  <p :if={version.published_at} class="mt-0.5 text-xs text-ink-subtle">
                    Published {Calendar.strftime(version.published_at, "%b %d, %Y")}
                  </p>
                </div>
                <.button
                  navigate={~p"/apps/#{@app.slug}/deploy"}
                  size="sm"
                  id={"deploy-#{version.id}"}
                  data-testid={"deploy-#{version.version}"}
                >
                  Deploy
                </.button>
              </div>
              <p :if={version.release_notes} class="text-sm text-ink-muted">
                <%!-- pre-line rides the span — same phantom-line fix as the
                poster description above (T4 review). --%>
                <span class="whitespace-pre-line">{version.release_notes}</span>
              </p>
              <div class="flex flex-wrap gap-2">
                <.badge>{version.default_cpu_cores} CPU</.badge>
                <.badge>{version.default_memory_mb} MB RAM</.badge>
                <.badge>{version.default_storage_gb} GB storage</.badge>
                <.price_badge version={version} />
              </div>
            </.card>
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

  # ADR-0028's live estimate. Hidden rather than crash on a nil size:
  # pre-#125 rows heal through seed convergence, not a backfill.
  defp price_badge(assigns) do
    ~H"""
    <.badge
      :if={@version.recommended_size}
      tone="primary"
      data-testid={"price-#{@version.version}"}
    >
      {FluxVale.Pricing.format_monthly_rate(@version.recommended_size.monthly_cents)}
    </.badge>
    """
  end
end
