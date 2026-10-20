defmodule FluxValeWeb.SitemapXML do
  @moduledoc """
  `/sitemap.xml` document builder (#164, ADR-00025 §3+4).

  Deliberately NOT a `.heex` template: LiveView's `root_tag_attribute`
  (`phx-r`, config.exs — diff-tracking aid for HTML templates) injects a
  **valueless** attribute into the compiled template's root tag, and XML
  requires every attribute to carry a value — a HEEx sitemap ships
  `<urlset phx-r …>` and stops being well-formed. Plain XML building keeps
  the sitemap parser-clean.

  All URLs are the canonical prod origin always (staging serves prod URLs
  by design, ADR-00025). Blog posts join when `/blog` lands.
  """

  alias FluxValeWeb.Seo

  @urlset_xmlns "http://www.sitemaps.org/schemas/sitemap/0.9"

  @doc """
  Builds the urlset for `home + /catalog + one URL per app (lastmod =
  the app's updated_at date)`.
  """
  @spec build([struct()]) :: iodata()
  def build(apps) do
    static_urls = [Seo.canonical_origin() <> "/", Seo.canonical_origin() <> "/catalog"]

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<urlset xmlns="#{@urlset_xmlns}">),
      for loc <- static_urls do
        ["<url><loc>", escape(loc), "</loc></url>"]
      end,
      for app <- apps do
        [
          "<url><loc>",
          escape(Seo.canonical_origin() <> "/catalog/#{app.slug}"),
          "</loc><lastmod>",
          lastmod(app),
          "</lastmod></url>"
        ]
      end,
      "</urlset>"
    ]
  end

  defp lastmod(app) do
    app.updated_at
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  # Defensive only — slugs are [a-z0-9-] and dates are ISO, nothing here
  # can carry XML-specials today; the escape keeps that true if the URL
  # set ever grows (query strings, blog titles).
  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
