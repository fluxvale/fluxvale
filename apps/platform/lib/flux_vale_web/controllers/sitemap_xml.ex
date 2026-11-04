defmodule FluxValeWeb.SitemapXML do
  @moduledoc """
  `/sitemap.xml` document builder (#164, ADR-00025 §3+4; blog posts
  joined with the blog lane, feedback with the board lane #412).

  Deliberately NOT a `.heex` template: LiveView's `root_tag_attribute`
  (`phx-r`, config.exs — diff-tracking aid for HTML templates) injects a
  **valueless** attribute into the compiled template's root tag, and XML
  requires every attribute to carry a value — a HEEx sitemap ships
  `<urlset phx-r …>` and stops being well-formed. Plain XML building keeps
  the sitemap parser-clean.

  All URLs are the canonical prod origin always (staging serves prod URLs
  by design, ADR-00025). Drafts never appear — the sitemap mirrors
  exactly what the prod blog index and feed advertise. Every feedback
  post appears (board pages are public and indexed from launch,
  ADR-0026 §4): declined and duplicate posts included, lastmod from
  `updated_at`. The roadmap (#412 T9) joins the static slice with a
  lastmod: the latest `status_changed_at` across posts (every move
  stamps it; the moves that reshape the roadmap's columns are all but
  the two open exits, decline and duplicate fold).
  """

  alias FluxVale.Blog.Post
  alias FluxValeWeb.Seo
  alias FluxValeWeb.XML

  @urlset_xmlns "http://www.sitemaps.org/schemas/sitemap/0.9"

  @doc """
  Builds the urlset for `home + /catalog + /pricing + /feedback + /blog +
  published policy pages + one URL per app (lastmod = the app's
  updated_at date) + one URL per published blog post (lastmod = the
  post's date) + one URL per feedback post (lastmod = updated_at)`.
  /roadmap rides the static slice with its own lastmod (the latest
  feedback status_changed_at, T9).
  """
  @spec build([struct()], [Post.t()], [FluxVale.Feedback.Post.t()]) :: iodata()
  def build(apps, posts, feedback_posts) do
    # ADR-00025 §3's static slice: the landing, the catalog index, the
    # pricing page (#396), the feedback board (#412), the blog index,
    # and the published policy pages (#140) — canonical public URLs
    # without a lastmod (nothing timestamped to show).
    static_urls = [
      Seo.canonical_origin() <> "/",
      Seo.canonical_origin() <> "/catalog",
      Seo.canonical_origin() <> "/pricing",
      Seo.canonical_origin() <> "/feedback",
      Seo.canonical_origin() <> "/blog",
      Seo.canonical_origin() <> "/policies/refund",
      Seo.canonical_origin() <> "/policies/terms",
      Seo.canonical_origin() <> "/policies/acceptable-use"
    ]

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<urlset xmlns="#{@urlset_xmlns}">),
      for loc <- static_urls do
        ["<url><loc>", XML.escape(loc), "</loc></url>"]
      end,
      roadmap_url(feedback_posts),
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
      for post <- feedback_posts do
        [
          "<url><loc>",
          XML.escape(Seo.canonical_origin() <> "/feedback/#{post.slug}"),
          "</loc><lastmod>",
          lastmod(post),
          "</lastmod></url>"
        ]
      end,
      "</urlset>"
    ]
  end

  defp lastmod(struct) do
    date(struct.updated_at)
  end

  # #412 T9: the roadmap row — a static URL WITH a lastmod, the latest
  # status_changed_at across posts (every move stamps it; the moves that
  # reshape the roadmap's columns are all but the two open exits,
  # decline and duplicate fold). No moved post yet renders it like the
  # other statics: bare loc, no lastmod.
  defp roadmap_url(feedback_posts) do
    loc = Seo.canonical_origin() <> "/roadmap"

    case latest_status_changed_at(feedback_posts) do
      nil ->
        ["<url><loc>", XML.escape(loc), "</loc></url>"]

      at ->
        ["<url><loc>", XML.escape(loc), "</loc><lastmod>", date(at), "</lastmod></url>"]
    end
  end

  # Enum.max's empty fallback keeps a board with no status moves (day
  # one prod: every post open) on the bare-loc shape.
  defp latest_status_changed_at(posts) do
    posts
    |> Enum.map(& &1.status_changed_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp date(datetime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end
end
