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
      nav_section={@nav_section}
      bare
    >
      <div class="appgram contents">
        <%!-- 1. The sunken band carries the app's identity: mono category
        eyebrow, name on the working-page scale, tagline + description.
        The Deploy CTA rides the band header's posture (dashboard /
        instances index) and lands on the same stepper entry the version
        cards' buttons use. No straddle — list/detail pages stay calm. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <.button variant="ghost" size="sm" navigate={~p"/apps"} class="-ml-2">
                &larr; Catalog
              </.button>

              <p class="eyebrow mt-4">{@app.category.name}</p>

              <div class="mt-1.5 flex flex-wrap items-start justify-between gap-x-6 gap-y-4">
                <div class="flex min-w-0 items-center gap-4">
                  <div class="grid size-12 shrink-0 place-items-center rounded-control bg-primary-muted text-lg font-semibold text-link sm:size-14 sm:text-xl">
                    <img
                      :if={@app.icon_url}
                      src={@app.icon_url}
                      alt={@app.name}
                      class="size-8 rounded-control sm:size-9"
                    />
                    <span :if={is_nil(@app.icon_url)}>{String.first(@app.name)}</span>
                  </div>
                  <div class="min-w-0">
                    <h1 class="page-title">{@app.name}</h1>
                    <p :if={@app.tagline} class="mt-1 text-base text-ink-muted">{@app.tagline}</p>
                  </div>
                </div>

                <div class="flex shrink-0 gap-2">
                  <%!-- No versions, no stepper: the wizard's step 1 would
                    list nothing (an app can exist before its first
                    version; #341 review). --%>
                  <.button :if={@versions != []} navigate={~p"/apps/#{@app.slug}/deploy"}>
                    Deploy
                  </.button>
                </div>
              </div>

              <p
                :if={is_binary(@app.description) and String.trim(@app.description) != ""}
                class="mt-4 max-w-prose leading-relaxed text-ink-muted"
              >
                <%!-- pre-line rides the span: the p's own whitespace is
                normal, so the template's indentation newlines collapse
                instead of laying out a phantom blank line (T4 review). --%>
                <span class="whitespace-pre-line">{String.trim(@app.description)}</span>
              </p>

              <div class="mt-4 flex flex-wrap items-center gap-3 text-sm">
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
        </section>

        <%!-- 2. Versions — the page's existing content in grammar cards
        (the <.card> rest step IS the grammar's card: raised, line-strong,
        shadow-sm). They host buttons, so no hover lift. --%>
        <section class="wrap pt-14 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
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
                  <%!-- pre-line rides the span — same phantom-line fix as
                  the band description above (T4 review). --%>
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
        </section>
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
