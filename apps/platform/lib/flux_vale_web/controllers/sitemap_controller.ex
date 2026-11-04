defmodule FluxValeWeb.SitemapController do
  @moduledoc """
  /sitemap.xml (#164, ADR-00025 §3+4): the prod-origin URL set — home,
  the catalog index, the blog index, one URL per catalog app with its
  updated_at lastmod, and one URL per published blog post (lastmod =
  the post's date). The document itself is built by
  `FluxValeWeb.SitemapXML` (why not HEEx: see that module — LiveView's
  root-tag attribute injection breaks XML well-formedness).
  """

  use FluxValeWeb, :controller

  alias FluxVale.Blog
  alias FluxVale.Blog
  alias FluxVale.Catalog.App
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

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, SitemapXML.build(apps, Blog.published()))
  end
end
