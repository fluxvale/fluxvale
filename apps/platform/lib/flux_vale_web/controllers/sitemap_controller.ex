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

  alias FluxVale.Catalog.App
  alias FluxValeWeb.SitemapXML

  def show(conn, _params) do
    apps =
      App
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> Ash.Query.sort(:slug)
      |> Ash.read!()

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, SitemapXML.build(apps, FluxVale.Blog.published()))
  end
end
