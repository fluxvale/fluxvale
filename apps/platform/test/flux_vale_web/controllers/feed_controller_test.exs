defmodule FluxValeWeb.FeedControllerTest do
  @moduledoc false

  # async: false — the feed reads :persistent_term (global state); the
  # fixtures replace it and restore the real content set on exit.

  use FluxValeWeb.ConnCase, async: false

  import TestSupport.BlogFixtures

  alias FluxVale.Blog.Loader

  setup context do
    dir = post_dir(context.test)

    write_post!(
      dir,
      "feed-post",
      post_frontmatter("feed-post"),
      "The **body** with 'apostrophes' and <angles>."
    )

    write_post!(dir, "feed-draft", post_frontmatter("feed-draft", ["draft: true"]))

    Loader.load!(dir)
    on_exit(fn -> Loader.load!() end)
    :ok
  end

  describe "GET /blog/feed" do
    test "serves well-formed Atom with published posts only", %{conn: conn} do
      conn = get(conn, ~p"/blog/feed")
      xml = response(conn, 200)

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/atom+xml"
      # The prolog must land verbatim — an escaped &lt;?xml prolog is
      # character data before the root element and strict parsers
      # reject it (the sitemap test's rule; same builder class).
      assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"?>))
      # Well-formed, not just substring-plausible: a real parse (xmerl).
      parsed =
        xml
        |> String.to_charlist()
        |> :xmerl_scan.string()

      assert {_doc, []} = parsed
      refute xml =~ "phx-r"

      assert xml =~ "<title>FluxVale Blog</title>"
      assert xml =~ "<id>https://fluxvale.com/blog/feed</id>"
      assert xml =~ ~s(<link rel="self" href="https://fluxvale.com/blog/feed"/>)
      assert xml =~ "<updated>2026-10-31T00:00:00Z</updated>"

      assert xml =~ "<title>Post feed-post</title>"
      assert xml =~ "<id>https://fluxvale.com/blog/feed-post</id>"
      # RFC 4287 date constructs are full date-times, never bare dates.
      assert xml =~ "<published>2026-10-31T00:00:00Z</published>"
      assert xml =~ "<updated>2026-10-31T00:00:00Z</updated>"
      assert xml =~ "<author><name>Tester</name></author>"
      assert xml =~ "<summary type=\"text\">A test post about feed-post.</summary>"

      # Entry content is escaped HTML — feed readers decode it back.
      assert xml =~ "&lt;strong&gt;body&lt;/strong&gt;"
      assert xml =~ "&apos;apostrophes&apos;"

      # Drafts never ride the feed, on any host.
      refute xml =~ "feed-draft"
    end

    test "an empty blog still yields a valid feed", %{conn: conn} do
      dir = post_dir(:empty_blog)
      load_fixtures!(dir)

      conn = get(conn, ~p"/blog/feed")
      xml = response(conn, 200)

      assert xml =~ "<updated>1970-01-01T00:00:00Z</updated>"
      refute xml =~ "<entry>"
    end
  end

  test "a feed reader's Accept header does not negotiate away the feed", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/atom+xml")
      |> get(~p"/blog/feed")

    assert response(conn, 200) =~ "<feed"
  end

  describe "GET /feed.xml" do
    test "301s to the canonical feed URL", %{conn: conn} do
      conn = get(conn, "/feed.xml")

      assert conn.status == 301
      [location] = get_resp_header(conn, "location")
      assert location == "https://fluxvale.com/blog/feed"
    end
  end
end
