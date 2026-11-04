defmodule FluxValeWeb.SitemapController do
  @moduledoc """
  /sitemap.xml (#164, ADR-00025 §3+4): the prod-origin URL set — home,
  the catalog index, the feedback board (#412), the blog index, one URL
  per catalog app with its updated_at lastmod, one URL per published
  blog post (lastmod = the post's date), and one URL per feedback post
  (lastmod = updated_at; declined and duplicate posts included — public
  pages all, ADR-0026 §4). The document itself is built by
  `FluxValeWeb.SitemapXML` (why not HEEx: see that module — LiveView's
  root-tag attribute injection breaks XML well-formedness).
  """

  use FluxValeWeb, :controller

  alias FluxVale.Blog
  alias FluxVale.Catalog.App
  alias FluxVale.Feedback.Post
  alias FluxValeWeb.SitemapXML

  def show(conn, _params) do
    # Dev hot reload rides here too (CodeRabbit + hostile review #326):
    # without it a freshly authored post showed on /blog and the feed
    # but not on the sitemap until another blog route was hit.
    Blog.maybe_hot_reload()

    apps =
      App
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> Ash.Query.sort(:slug)
      |> Ash.read!()

    feedback_posts =
      Post
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> Ash.Query.sort(:slug)
      # Unbounded read, conscious acceptance: the first user-generated
      # table in this query, but day-one row counts are small. Revisit
      # at growth (pagination or a sitemap index).
      |> Ash.read!()

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, SitemapXML.build(apps, Blog.published(), feedback_posts))
  end
end
