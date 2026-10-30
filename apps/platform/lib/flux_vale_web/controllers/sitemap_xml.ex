defmodule FluxValeWeb.SitemapXML do
  @moduledoc """
  `/sitemap.xml` document builder (#164, ADR-00025 §3+4; blog posts
  joined with the blog lane, as this module always planned).

  Deliberately NOT a `.heex` template: LiveView's `root_tag_attribute`
  (`phx-r`, config.exs — diff-tracking aid for HTML templates) injects a
  **valueless** attribute into the compiled template's root tag, and XML
  requires every attribute to carry a value — a HEEx sitemap ships
  `<urlset phx-r …>` and stops being well-formed. Plain XML building keeps
  the sitemap parser-clean.

  All URLs are the canonical prod origin always (staging serves prod URLs
  by design, ADR-00025). Drafts never appear — the sitemap mirrors
  exactly what the prod blog index and feed advertise.
  """

  alias FluxVale.Blog.Post
  alias FluxValeWeb.Seo
  alias FluxValeWeb.XML

  @urlset_xmlns "http://www.sitemaps.org/schemas/sitemap/0.9"

  @doc """
  Builds the urlset for `home + /catalog + /blog + published policy
  pages + one URL per app (lastmod = the app's updated_at date) + one
  URL per published post (lastmod = the post's date)`.
  """
  @spec build([struct()], [Post.t()]) :: iodata()
  def build(apps, posts) do
    # ADR-00025 §3's static slice: the landing, the catalog index, the
    # blog index, and the published policy pages (#140) — canonical
    # public URLs without a lastmod (nothing timestamped to show).
    static_urls = [
      Seo.canonical_origin() <> "/",
      Seo.canonical_origin() <> "/catalog",
      Seo.canonical_origin() <> "/blog",
      Seo.canonical_origin() <> "/policies/refund"
    ]

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<urlset xmlns="#{@urlset_xmlns}">),
      for loc <- static_urls do
        ["<url><loc>", XML.escape(loc), "</loc></url>"]
      end,
      for app <- apps do
        [
          "<url><loc>",
          XML.escape(Seo.canonical_origin() <> "/catalog/#{app.slug}"),
          "</loc><lastmod>",
          lastmod(app),
          "</lastmod></url>"
        ]
      end,
      for post <- posts do
        [
          "<url><loc>",
          XML.escape(Seo.canonical_origin() <> "/blog/#{post.slug}"),
          "</loc><lastmod>",
          Date.to_iso8601(post.date),
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
end
