defmodule FluxValeWeb.SitemapControllerTest do
  @moduledoc false

  # async: false — the urlset now includes the blog's persistent_term
  # posts (global state); blog fixtures replace them and restore on exit.

  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.Blog.Loader
  alias FluxVale.TestSupport.InstanceFixtures
  alias TestSupport.BlogFixtures

  setup context do
    dir = BlogFixtures.post_dir(context.test)
    post = BlogFixtures.post_frontmatter("sitemap-post")
    BlogFixtures.write_post!(dir, "sitemap-post", post)

    draft = BlogFixtures.post_frontmatter("sitemap-draft", ["draft: true"])
    BlogFixtures.write_post!(dir, "sitemap-draft", draft)

    Loader.load!(dir)
    on_exit(fn -> Loader.load!() end)
    :ok
  end

  test "the urlset lists home, the catalog, and every app at the prod origin", %{conn: conn} do
    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, [app: :category], authorize?: false).app

    conn = get(conn, ~p"/sitemap.xml")
    xml = response(conn, 200)
    content_type = get_resp_header(conn, "content-type")

    lastmod =
      app.updated_at
      |> DateTime.to_date()
      |> Date.to_iso8601()

    assert conn.status == 200
    assert List.first(content_type) =~ "application/xml"
    # The declaration must land verbatim — an escaped &lt;?xml prolog is
    # character data before the root element and strict parsers reject it.
    assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"?>))
    # Well-formed, not just substring-plausible: a real parse (xmerl) and
    # no root-tag attribute injection (phx-r is valueless — invalid XML).
    parsed =
      xml
      |> String.to_charlist()
      |> :xmerl_scan.string()

    assert {_doc, []} = parsed
    refute xml =~ "phx-r"
    assert xml =~ "<loc>https://fluxvale.com/</loc>"
    assert xml =~ "<loc>https://fluxvale.com/catalog</loc>"
    assert xml =~ "<loc>https://fluxvale.com/catalog/#{app.slug}</loc>"
    assert xml =~ "<lastmod>#{lastmod}</lastmod>"
  end

  test "an empty catalog still lists the static URLs", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    xml = response(conn, 200)

    assert conn.status == 200
    assert xml =~ "<loc>https://fluxvale.com/</loc>"
    assert xml =~ "<loc>https://fluxvale.com/catalog</loc>"
    refute xml =~ "/catalog/app-"
  end

  test "the published policy page is a static URL (#140)", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    xml = response(conn, 200)

    assert xml =~ "<loc>https://fluxvale.com/policies/refund</loc>"
  end

  test "the blog index is static and posts carry their dates (ADR-00025 §1)", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    xml = response(conn, 200)

    assert xml =~ "<loc>https://fluxvale.com/blog</loc>"
    assert xml =~ "<loc>https://fluxvale.com/blog/sitemap-post</loc>"

    assert xml =~
             ~s(<loc>https://fluxvale.com/blog/sitemap-post</loc><lastmod>2026-10-31</lastmod>)

    # Drafts never ride the sitemap (ADR-00025: excluded everywhere).
    refute xml =~ "sitemap-draft"
  end
end
