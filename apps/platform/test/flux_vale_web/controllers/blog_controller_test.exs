defmodule FluxValeWeb.BlogControllerTest do
  @moduledoc false

  # async: false — the blog rides :persistent_term (global state); the
  # fixtures replace it and restore the real content set on exit.

  use FluxValeWeb.ConnCase, async: false

  import TestSupport.BlogFixtures

  alias FluxVale.Blog.Loader

  @canonical_host "fluxvale.com"

  setup context do
    dir = post_dir(context.test)

    write_post!(dir, "fixture-post", post_frontmatter("fixture-post"), "The **body**.")
    write_post!(dir, "fixture-draft", post_frontmatter("fixture-draft", ["draft: true"]))

    Loader.load!(dir)
    on_exit(fn -> Loader.load!() end)
    :ok
  end

  describe "GET /blog" do
    test "lists posts with the blog SEO head and feed autodiscovery", %{conn: conn} do
      conn = get(conn, ~p"/blog")
      html = html_response(conn, 200)

      # The test host is non-canonical — drafts are listed for preview.
      assert html =~ "fixture-post"
      assert html =~ "fixture-draft"

      assert html =~ "Blog · FluxVale</title>"
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/blog">)
      assert html =~ ~s(rel="alternate")
      assert html =~ ~s(href="https://fluxvale.com/blog/feed")
      assert html =~ ~s(type="application/atom+xml")
    end

    test "the canonical prod host hides drafts", %{conn: conn} do
      conn = get(%{conn | host: @canonical_host}, ~p"/blog")
      html = html_response(conn, 200)

      assert html =~ "fixture-post"
      refute html =~ "fixture-draft"
    end
  end

  describe "GET /blog/:slug" do
    test "renders the post with the full SEO plumbing", %{conn: conn} do
      conn = get(conn, ~p"/blog/fixture-post")
      html = html_response(conn, 200)

      assert html =~ "Post fixture-post · FluxVale</title>"
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/blog/fixture-post">)
      assert html =~ ~s(property="og:type" content="article">)
      assert html =~ ~s(property="article:published_time" content="2026-10-31">)

      assert html =~ ~s(property="og:image" content="https://fluxvale.com/images/og-default.png">)

      assert html =~ "1 min read"
      # The body is rendered markdown, not raw source.
      assert html =~ "The <strong>body</strong>."

      # JSON-LD Article block (catalog's html_safe pattern) — inside its
      # script wrapper, never visible text (phx-r injects into the tag).
      assert html =~ ~s(type="application/ld+json" id="ld-json-blog-post">)
      assert html =~ ~s("@type":"Article")
      assert html =~ ~s("headline":"Post fixture-post")
      assert html =~ ~s("datePublished":"2026-10-31")
      # html_safe JSON escapes "/" as \/ (the </script> breakout guard).
      assert html =~ ~S("mainEntityOfPage":"https:\/\/fluxvale.com\/blog\/fixture-post")
    end

    test "og_image frontmatter overrides the default OG image", %{conn: conn} do
      dir = post_dir(:og_override)

      write_post!(dir, "og-post", post_frontmatter("og-post", ["og_image: /images/mark.svg"]))
      load_fixtures!(dir)

      conn = get(conn, ~p"/blog/og-post")
      html = html_response(conn, 200)

      assert html =~ ~s(property="og:image" content="https://fluxvale.com/images/mark.svg">)
    end

    test "a draft renders on a non-canonical host under noindex", %{conn: conn} do
      conn = get(conn, ~p"/blog/fixture-draft")
      html = html_response(conn, 200)

      assert html =~ "Post fixture-draft"
      # The preview can never leak into an index (SeoNoindex).
      assert html =~ ~s(name="robots" content="noindex, nofollow">)
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    test "a draft 404s on the canonical host", %{conn: conn} do
      conn = get(%{conn | host: @canonical_host}, ~p"/blog/fixture-draft")

      assert response(conn, 404)
    end

    test "an unknown slug is a real 404", %{conn: conn} do
      conn = get(conn, ~p"/blog/no-such-post")

      assert response(conn, 404)
    end
  end
end
