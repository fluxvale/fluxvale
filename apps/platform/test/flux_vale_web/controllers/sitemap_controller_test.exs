defmodule FluxValeWeb.SitemapControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.InstanceFixtures

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
end
