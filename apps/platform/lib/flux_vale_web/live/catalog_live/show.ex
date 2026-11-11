defmodule FluxValeWeb.CatalogLive.Show do
  @moduledoc """
  App detail (#74): the public catalog page's marketing content — the
  same `CatalogPageComponents` sections, S2-S4 — followed by the
  version cards and the deploy stepper's entry (#611 S6, D12). The
  page reads the catalog through `Catalog.App.get_by_slug/2`, exactly
  like the public SSR page.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog
  alias FluxVale.Observability.WakeStats
  alias FluxVale.Pricing
  alias FluxValeWeb.CatalogPageComponents
  alias FluxValeWeb.CatalogPageContent

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Catalog.App.get_by_slug(slug, actor: user) do
      {:ok, app} ->
        # The public controller's read, mirrored (#611 S6): the category
        # rides with its apps for the similar section, versions carry
        # the recommended size for the cards' rates and the pricing card.
        app = Ash.load!(app, [category: :apps, app_versions: :recommended_size], actor: user)
        versions = sorted_desc(app.app_versions)

        {:ok,
         assign(socket,
           app: app,
           versions: versions,
           newest_version: List.first(versions),
           wake_estimates: WakeStats.median_total_by_app_safe(),
           similar_apps: CatalogPageContent.similar_apps(app, app.category.apps),
           from_price_cents: Pricing.from_price_cents()
         )}

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
      <%!-- #611 S6 (plan §10, D12): the authenticated page is the public
      page — the hero with its pricing and facts cards, the curated
      sections, then the generated ones — with the version cards the
      deploy stepper needs appended below the marketing content. The
      chrome's measure is mirrored here because `bare` drops main's
      container. --%>
      <div class="catalog-page mx-auto w-full max-w-5xl px-4 py-10 sm:px-6 lg:px-8">
        <div class="pt-6 pb-12">
          <CatalogPageComponents.hero
            app={@app}
            newest_version={@newest_version}
            wake_estimates={@wake_estimates}
            back_path="/apps"
            welcome_credit?={false}
          />
        </div>

        <CatalogPageComponents.in_action app={@app} />
        <CatalogPageComponents.features app={@app} />
        <CatalogPageComponents.benefits app={@app} newest_version={@newest_version} />
        <CatalogPageComponents.faq app={@app} newest_version={@newest_version} />
        <CatalogPageComponents.similar_apps
          peers={@similar_apps}
          from_price_cents={@from_price_cents}
          catalog_path="/apps"
        />
        <CatalogPageComponents.closing_cta
          app={@app}
          newest_version={@newest_version}
          catalog_path="/apps"
        />

        <%!-- The page's existing content, unchanged: one card per
        published version, each the deploy stepper's entry. --%>
        <section class="border-t border-line py-14 sm:py-16" id="versions">
          <h2 class="display-h2" data-testid="versions-heading">Versions</h2>

          <.empty_state :if={@versions == []} title="No versions published yet." />

          <div class="mt-8 space-y-4">
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
                the hero description (T4 review). --%>
                <span class="whitespace-pre-line">{version.release_notes}</span>
              </p>
              <div class="flex flex-wrap gap-2">
                <.badge>{version.default_cpu_cores} CPU</.badge>
                <.badge>{version.default_memory_mb} MB RAM</.badge>
                <.badge>{version.default_storage_gb} GB storage</.badge>
                <.price_badge version={version} />
                <.stopped_rate version={version} />
                <%!-- #398: pricing is one hop away — the card shows
                this version's plan, /pricing prices every resource
                (#558: compute classes and storage price apart, so
                no sizes list exists to link at). --%>
                <.link
                  navigate={~p"/pricing"}
                  class="self-center text-sm font-medium text-link hover:underline"
                  data-testid={"see-all-sizes-#{version.version}"}
                >
                  {gettext("See pricing")}
                </.link>
              </div>
            </.card>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # #700: newest-first on the maintained semver key (SetSortKey owns
  # the encoding) — the :list_for_app sort, mirrored.
  defp sorted_desc(versions), do: Enum.sort_by(versions, & &1.sort_key, :desc)

  # ADR-0028's live estimate. #558: the recommended compute class's
  # rate plus the storage axis at the version's own default — priced
  # through Pricing.version_rates/1, never the size row alone (its
  # monthly rate carries no storage). Hidden rather than crash on a
  # sizeless version: pre-#125 rows heal through seed convergence, not
  # a backfill.
  defp price_badge(assigns) do
    assigns = assign(assigns, :rates, FluxVale.Pricing.version_rates(assigns.version))

    ~H"""
    <.badge
      :if={@rates}
      tone="primary"
      data-testid={"price-#{@version.version}"}
    >
      {FluxVale.Pricing.format_monthly_rate(@rates.monthly_cents)}
    </.badge>
    """
  end

  # #398: the storage-only fee beside the running rate — ADR-0028 §2,
  # in the /pricing table's "%{rate}/mo while stopped" idiom. #558: it
  # is the storage axis alone, from the same version_rates read. Hidden
  # with the price badge on a sizeless version.
  defp stopped_rate(assigns) do
    assigns = assign(assigns, :rates, FluxVale.Pricing.version_rates(assigns.version))

    ~H"""
    <.badge :if={@rates} data-testid={"stopped-price-#{@version.version}"}>
      {gettext("%{rate}/mo while stopped",
        rate: FluxVale.Pricing.format_usd(@rates.stopped_monthly_cents)
      )}
    </.badge>
    """
  end
end
