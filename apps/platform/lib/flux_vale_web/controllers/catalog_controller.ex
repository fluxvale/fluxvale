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
  alias FluxValeWeb.CatalogPageContent
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
        # category: :apps feeds the similar-apps section (S3): the
        # category's apps loaded once here, shaped by the pure
        # CatalogPageContent.similar_apps/2 in the assign below.
        app = Ash.load!(app, [category: :apps, app_versions: :recommended_size], actor: nil)
        versions = sorted_desc(app.app_versions)
        newest_version = List.first(versions)

        conn
        # #611 plan §9: the title matches the H1 and the search intent.
        |> assign(:page_title, "#{app.name} hosting · FluxVale")
        |> assign(:page_description, app.tagline || @catalog_description)
        |> assign(:canonical_path, "/catalog/#{app.slug}")
        # S5: both JSON-LD payloads ground in what the page renders —
        # the SoftwareApplication's offer prices the newest version,
        # the FAQPage mirrors the rendered FAQ items.
        |> assign(:json_ld, json_ld(app, newest_version))
        |> assign(:faq_json_ld, faq_json_ld(app, newest_version))
        |> assign(:app, app)
        |> assign(:newest_version, newest_version)
        |> assign(:wake_estimates, WakeStats.median_total_by_app_safe())
        |> assign(:similar_apps, CatalogPageContent.similar_apps(app, app.category.apps))
        # The similar-cards' from-price: the compute floor, computed
        # once per request like the index's.
        |> assign(:from_price_cents, Pricing.from_price_cents())
        |> render(:show)

      # Unknown slugs read as "not here" — a real 404, unlike the
      # authenticated LiveView's redirect (the public page may be
      # linked/crawled; a 302 would lie to crawlers).
      _error ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: FluxValeWeb.Router
    end
  end

  # #611 S5 (plan §9): the SoftwareApplication payload grows only what
  # the page grounds — the description's first paragraph, the offer off
  # the pricing card's rate seam, absolute screenshot URLs, feature
  # titles. Absent sources omit their keys entirely: a null or empty
  # value would be a claim the page cannot back (no invented fields).
  defp json_ld(app, newest_version) do
    # :html_safe — Jason's default :json mode leaves <, >, and / raw, and
    # this lands in a <script> via raw/1; a </script> inside app data must
    # not break out of the JSON-LD block.
    payload =
      %{
        "@context" => "https://schema.org",
        "@type" => "SoftwareApplication",
        "name" => app.name,
        # The authored description's first paragraph — the hero's lead
        # prose, what a crawler should quote. A null must never ship:
        # tagline, then the catalog default (:page_description's ladder
        # one rung deeper).
        "description" => app_description(app),
        "url" => Seo.canonical_origin() <> "/catalog/#{app.slug}",
        "applicationCategory" => app.category.name,
        "operatingSystem" => "Web"
      }
      |> maybe_put("offers", offers(newest_version))
      |> maybe_put("screenshot", screenshots(app.screenshots))
      |> maybe_put("featureList", feature_list(app.features))

    Jason.encode!(payload, escape: :html_safe)
  end

  # The FAQPage payload (plan §9): built from the exact items the FAQ
  # section renders — setup column then about column, the app's own
  # questions appended once — so the markup and the visible questions
  # cannot drift. Links are page furniture and stay out; `open` is a
  # presentation state, not data.
  defp faq_json_ld(app, newest_version) do
    items =
      CatalogPageContent.faq_setup_items(app, newest_version) ++
        CatalogPageContent.faq_about_items(app)

    questions =
      Enum.map(items, fn item ->
        %{
          "@type" => "Question",
          "name" => item.question,
          "acceptedAnswer" => %{"@type" => "Answer", "text" => item.answer}
        }
      end)

    Jason.encode!(
      %{
        "@context" => "https://schema.org",
        "@type" => "FAQPage",
        "mainEntity" => questions
      },
      escape: :html_safe
    )
  end

  # An absent source (a versionless app, a sizeless version) drops its
  # key rather than shipping a null or empty value.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp app_description(app) do
    case first_paragraph(app.description) do
      nil -> app.tagline || @catalog_description
      paragraph -> paragraph
    end
  end

  # The description's first paragraph: blank-line split (the hero's
  # whitespace-pre-line paragraph breaks), trimmed, first non-empty —
  # a wrapped single paragraph stays whole. The \r? arms keep CRLF
  # paragraphs (textarea input normalizes to \r\n) splitting the same
  # way LF seed YAML does.
  defp first_paragraph(nil), do: nil

  defp first_paragraph(description) do
    description
    |> String.split(~r/\r?\n[ \t]*\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end

  # The offer prices through the same seam the pricing card does —
  # version_rates on the newest version; nil on a versionless app or a
  # sizeless version (the unpriced drift shape), and the key drops out.
  defp offers(nil), do: nil

  defp offers(newest_version) do
    case Pricing.version_rates(newest_version) do
      nil ->
        nil

      %{monthly_cents: monthly_cents} ->
        %{
          "@type" => "Offer",
          "price" => offer_price(monthly_cents),
          "priceCurrency" => "USD"
        }
    end
  end

  # schema.org's Offer.price is a bare two-decimal figure ("3.35") —
  # format_usd's digits (one formatting seam) with the "$" trimmed.
  defp offer_price(monthly_cents) do
    formatted = Pricing.format_usd(monthly_cents)
    String.trim_leading(formatted, "$")
  end

  # Crawlers cannot resolve the page-relative src — absolute canonical
  # URLs (plan §9). The ScreenshotList type normalizes nil to [] at
  # cast, so [] is the single absent state.
  defp screenshots([]), do: nil

  defp screenshots(screenshots) do
    origin = Seo.canonical_origin()
    Enum.map(screenshots, &(origin <> &1.src))
  end

  # Feature titles only — icons and bodies are page furniture. Same
  # nil-to-[] contract as screenshots.
  defp feature_list([]), do: nil

  defp feature_list(features), do: Enum.map(features, & &1.title)

  # #700: newest-first on the maintained semver key (SetSortKey owns
  # the encoding) — the :list_for_app sort, mirrored.
  defp sorted_desc(versions), do: Enum.sort_by(versions, & &1.sort_key, :desc)
end
