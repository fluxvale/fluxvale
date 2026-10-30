defmodule FluxValeWeb.BlogController do
  @moduledoc """
  The blog's SSR surface (ADR-00025 §1): `/blog` and `/blog/:slug` —
  plain controller+HEEx, never LiveView, so crawlers get the full
  document with zero JS. Posts come boot-compiled from
  `FluxVale.Blog` (persistent_term reads).

  Draft policy (ADR-00025 §1+§4): drafts are excluded from the
  sitemap/feed everywhere, and on the **canonical prod host** they 404;
  every other host (staging, PR review envs, local dev) lists and
  renders them so every post PR gets a live preview.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Blog
  alias FluxVale.Blog.Post
  alias FluxValeWeb.Plugs.SeoNoindex
  alias FluxValeWeb.Seo

  @blog_description "Updates and guides from the FluxVale team"

  def index(conn, _params) do
    Blog.maybe_hot_reload()

    # Drafts ride the index only off the canonical host — on prod the
    # blog lists exactly what the sitemap and feed advertise.
    posts =
      if SeoNoindex.canonical_host?(conn) do
        Blog.published()
      else
        Blog.all()
      end

    conn
    |> assign(:page_title, "Blog · FluxVale")
    |> assign(:page_description, @blog_description)
    |> assign(:canonical_path, "/blog")
    |> assign(:posts, posts)
    |> render(:index)
  end

  def show(conn, %{"slug" => slug}) do
    Blog.maybe_hot_reload()

    case Blog.get(slug) do
      %Post{draft: true} = post ->
        # The prod host reads a draft as "not here" — a real 404, never
        # a redirect (the URL may be publicly guessed/linked). Non-prod
        # hosts preview it (the noindex plug already covered them).
        if SeoNoindex.canonical_host?(conn) do
          raise Phoenix.Router.NoRouteError, conn: conn, router: FluxValeWeb.Router
        else
          render_post(conn, post)
        end

      %Post{} = post ->
        render_post(conn, post)

      nil ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: FluxValeWeb.Router
    end
  end

  defp render_post(conn, post) do
    conn
    |> assign(:page_title, "#{post.title} · FluxVale")
    |> assign(:page_description, post.description)
    |> assign(:canonical_path, "/blog/#{post.slug}")
    |> assign(:og_image_path, post.og_image)
    |> assign(:og_type, "article")
    |> assign(:article_published_time, Date.to_iso8601(post.date))
    |> assign(:json_ld, json_ld(post))
    |> assign(:post, post)
    |> render(:show)
  end

  defp json_ld(post) do
    # :html_safe — this lands in a <script> via raw/1; a </script> inside
    # post data must not break out of the JSON-LD block (catalog's rule).
    Jason.encode!(
      %{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => post.title,
        "description" => post.description,
        "datePublished" => Date.to_iso8601(post.date),
        "author" => %{"@type" => "Person", "name" => post.author},
        "image" => Seo.canonical_origin() <> (post.og_image || Seo.default_og_image_path()),
        "mainEntityOfPage" => Seo.canonical_origin() <> "/blog/#{post.slug}",
        "publisher" => %{"@type" => "Organization", "name" => "FluxVale"}
      },
      escape: :html_safe
    )
  end
end
