defmodule FluxValeWeb.SitemapControllerTest do
  @moduledoc false

  # async: false — the urlset now includes the blog's persistent_term
  # posts (global state); blog fixtures replace them and restore on exit.

  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.Blog.Loader
  alias FluxVale.TestSupport.FeedbackFixtures
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

  test "the published policy pages are static URLs (#140, #365, fv332 D5)", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    xml = response(conn, 200)

    assert xml =~ "<loc>https://fluxvale.com/policies/refund</loc>"
    assert xml =~ "<loc>https://fluxvale.com/policies/terms</loc>"
    assert xml =~ "<loc>https://fluxvale.com/policies/acceptable-use</loc>"
    assert xml =~ "<loc>https://fluxvale.com/policies/privacy</loc>"
    # #511: the guide rides the published-page shape beside the policies.
    assert xml =~ "<loc>https://fluxvale.com/guides/sign-in-with-pocket-id</loc>"
  end

  # #396: the published pricing rides the static slice beside the
  # catalog — public, canonical, no lastmod.
  test "the pricing page is a static URL (#396)", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    xml = response(conn, 200)

    assert xml =~ "<loc>https://fluxvale.com/pricing</loc>"
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

  # #412 T4: the board index is a static URL and every post rides with
  # its updated_at lastmod — declined and duplicate included (public
  # pages all, ADR-0026 §4).
  test "the feedback board and every post are listed with lastmod", %{conn: conn} do
    open = FeedbackFixtures.post!(%{title: "Sitemap open request", description: "x"})
    declined = FeedbackFixtures.post!(%{title: "Sitemap declined request", description: "x"})
    FeedbackFixtures.move_status!(declined, :declined)
    original = FeedbackFixtures.post!(%{title: "Sitemap original request", description: "x"})
    dup = FeedbackFixtures.post!(%{title: "Sitemap duplicate request", description: "x"})
    FeedbackFixtures.move_status!(dup, :duplicate, duplicate_of: original)

    xml = response(get(conn, ~p"/sitemap.xml"), 200)

    assert xml =~ "<loc>https://fluxvale.com/feedback</loc>"

    for post <- [open, declined, dup] do
      lastmod =
        post.updated_at
        |> DateTime.to_date()
        |> Date.to_iso8601()

      assert xml =~
               "<loc>https://fluxvale.com/feedback/#{post.slug}</loc><lastmod>#{lastmod}</lastmod>"
    end

    # Well-formedness still holds with the feedback rows in the set.
    charlist = String.to_charlist(xml)
    assert {_doc, []} = :xmerl_scan.string(charlist)
  end

  # #412 T9: the roadmap joins the static slice with a lastmod — the
  # latest status_changed_at across posts (the last status move is what
  # last reshaped the board).
  test "the roadmap is listed with the latest status-change lastmod", %{conn: conn} do
    started = FeedbackFixtures.post!(%{title: "Sitemap roadmap started", description: "x"})
    FeedbackFixtures.move_status!(started, :started)
    FeedbackFixtures.set_status_changed_at!(started, hours_ago(48))

    to_complete = FeedbackFixtures.post!(%{title: "Sitemap roadmap completed", description: "x"})
    shipped = FeedbackFixtures.move_status!(to_complete, :completed)

    lastmod =
      shipped.status_changed_at
      |> DateTime.to_date()
      |> Date.to_iso8601()

    xml = response(get(conn, ~p"/sitemap.xml"), 200)

    assert xml =~ "<loc>https://fluxvale.com/roadmap</loc><lastmod>#{lastmod}</lastmod>"
  end

  test "the roadmap lists without a lastmod when no post has moved", %{conn: conn} do
    FeedbackFixtures.post!(%{title: "Sitemap roadmap never moved", description: "x"})

    xml = response(get(conn, ~p"/sitemap.xml"), 200)

    assert xml =~ "<loc>https://fluxvale.com/roadmap</loc></url>"
    refute xml =~ "roadmap</loc><lastmod>"
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)
end
