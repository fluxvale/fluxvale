defmodule FluxValeWeb.CatalogController do
  @moduledoc """
  The public catalog (#164, ADR-00025): SSR, anonymous-OK mirrors of the
  authenticated CatalogLive browse — the programmatic-SEO surface.
  Reads ride the public read policies (#164, actor: nil); the deploy CTA
  links at the existing auth-gated `/apps/:slug/deploy` stepper, so the
  auth boundary is untouched: anonymous click → the route's 302 to
  /sign-in; signed-in click → the stepper.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Observability.WakeStats
  alias FluxVale.Pricing
  alias FluxValeWeb.Seo

  @catalog_description "A curated catalog of open source apps, ready to run in minutes."

  def index(conn, _params) do
    categories = Category.list_with_apps!(actor: nil)

    conn
    |> assign(:page_title, "App catalog · FluxVale")
    |> assign(:page_description, @catalog_description)
    |> assign(:canonical_path, "/catalog")
    |> assign(:categories, categories)
    # The card from-price (#398, #558): the compute-class floor,
    # computed once per request — every card carries the same number,
    # and the copy adds storage separately (per GB, its own axis).
    |> assign(:from_price_cents, Pricing.from_price_cents())
    |> render(:index)
  end

  def show(conn, %{"slug" => slug}) do
    case App.get_by_slug(slug, actor: nil) do
      {:ok, app} ->
        app = Ash.load!(app, [:category, app_versions: :recommended_size], actor: nil)
        versions = sorted_desc(app.app_versions)

        conn
        # #611 plan §9: the title matches the H1 and the search intent.
        |> assign(:page_title, "#{app.name} hosting · FluxVale")
        |> assign(:page_description, app.tagline || @catalog_description)
        |> assign(:canonical_path, "/catalog/#{app.slug}")
        |> assign(:json_ld, json_ld(app))
        |> assign(:app, app)
        |> assign(:newest_version, List.first(versions))
        |> assign(:wake_estimates, WakeStats.median_total_by_app_safe())
        |> render(:show)

      # Unknown slugs read as "not here" — a real 404, unlike the
      # authenticated LiveView's redirect (the public page may be
      # linked/crawled; a 302 would lie to crawlers).
      _error ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: FluxValeWeb.Router
    end
  end

  defp json_ld(app) do
    # :html_safe — Jason's default :json mode leaves <, >, and / raw, and
    # this lands in a <script> via raw/1; a </script> inside app data must
    # not break out of the JSON-LD block.
    Jason.encode!(
      %{
        "@context" => "https://schema.org",
        "@type" => "SoftwareApplication",
        "name" => app.name,
        # Same fallback as :page_description — a tagline-less app must not
        # ship a null description to crawlers.
        "description" => app.tagline || @catalog_description,
        "url" => Seo.canonical_origin() <> "/catalog/#{app.slug}",
        "applicationCategory" => app.category.name,
        "operatingSystem" => "Web"
      },
      escape: :html_safe
    )
  end

  # Lexicographic on the version string — mirrors CatalogLive.Show (exact
  # while a seed carries one version per app; semver-aware sorting is a
  # #70-era non-problem).
  defp sorted_desc(versions), do: Enum.sort_by(versions, & &1.version, :desc)
end
