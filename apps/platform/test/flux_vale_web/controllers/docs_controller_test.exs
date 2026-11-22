defmodule FluxValeWeb.DocsControllerTest do
  @moduledoc false

  # async: false — the docs ride :persistent_term (global state); the
  # fixtures replace it and restore the real content set on exit.

  use FluxValeWeb.ConnCase, async: false

  import TestSupport.DocsFixtures

  alias FluxVale.Docs.Loader

  setup context do
    dir = content_dir(context.test)

    write_page!(dir, "guides", "fixture-page", page_frontmatter("fixture-page"), "The **body**.")
    write_page!(dir, "help", "fixture-faq", page_frontmatter("fixture-faq"))

    Loader.load!(dir)
    on_exit(fn -> Loader.load!() end)
    :ok
  end

  describe "GET /docs" do
    test "lists sections and pages with the docs SEO head", %{conn: conn} do
      conn = get(conn, ~p"/docs")
      html = html_response(conn, 200)

      assert html =~ "Docs · FluxVale</title>"
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/docs">)

      # Sections render in order, each with its page rows.
      assert html =~ "Guides"
      assert html =~ "Page fixture-page"
      assert html =~ "A test page about fixture-page."
      assert html =~ "Help"
      assert html =~ "Page fixture-faq"

      # #765: the agent handoff rides above the section map.
      assert html =~ ~s(data-testid="docs-agent-handoff")
      assert html =~ ~s(href="/docs/agents")

      # #881: the unified link-columns footer rides the docs surface
      # like every public page. Docs itself left the footer with the
      # flat footer's removal (ADR-0044 Am. 1) — reachability is the
      # landing header + the sitemap.
      assert html =~ ~s(data-testid="footer-guides")
      assert html =~ ~s(aria-label="Footer")
    end
  end

  describe "GET /docs/:section" do
    test "lists the section's pages with the sectioned sidebar", %{conn: conn} do
      conn = get(conn, ~p"/docs/guides")
      html = html_response(conn, 200)

      assert html =~ "Guides · FluxVale Docs</title>"
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/docs/guides">)

      assert html =~ "Page fixture-page"
      # The section lists only its own pages (the sidebar carries the
      # other sections' page titles, so the DESCRIPTION is the
      # content-side tell here).
      refute html =~ "A test page about fixture-faq."

      # The sidebar (ADR-0044 §5): every section present. A section
      # listing marks nothing current — only an article page carries
      # the active mark.
      assert html =~ ~s(aria-label="Documentation")
      assert html =~ ~s(href="/docs/guides/fixture-page")
      assert html =~ ~s(href="/docs/help/fixture-faq")

      # #799: the agent guide is the sidebar's first top-level entry,
      # above the content-derived sections (the index page's placement).
      document = LazyHTML.from_document(html)
      nav_links = LazyHTML.query(document, "nav.docs-nav a")
      nav_hrefs = LazyHTML.attribute(nav_links, "href")

      assert List.first(nav_hrefs) == "/docs/agents"
      assert "/docs/guides" in nav_hrefs

      refute html =~ ~s(aria-current="page")
    end

    test "an unknown section is a real 404", %{conn: conn} do
      conn = get(conn, ~p"/docs/no-such-section")

      assert response(conn, 404)
    end
  end

  describe "GET /docs/:section/:slug" do
    test "renders the page with sidebar nav and rendered markdown", %{conn: conn} do
      conn = get(conn, ~p"/docs/guides/fixture-page")
      html = html_response(conn, 200)

      assert html =~ "Page fixture-page · FluxVale Docs</title>"
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/docs/guides/fixture-page">)
      assert html =~ ~s(name="description" content="A test page about fixture-page.")

      # The breadcrumb names the section, the sidebar marks the page.
      assert html =~ ~s(href="/docs/guides">Guides)
      assert html =~ ~s(aria-label="Documentation")
      assert html =~ ~s(aria-current="page")

      # #799: the agent guide rides every docs sidebar; the article's
      # own link is the active one, not the agent entry.
      document = LazyHTML.from_document(html)
      agent_entry = LazyHTML.query(document, ~s(nav.docs-nav a[href="/docs/agents"]))
      agent_text = LazyHTML.text(agent_entry)
      entry_html = LazyHTML.to_html(agent_entry)

      assert String.trim(agent_text) == "Set up with your agent"
      refute entry_html =~ ~s(aria-current)
      refute entry_html =~ "docs-nav-link-active"

      # The body is rendered markdown, not raw source.
      assert html =~ "The <strong>body</strong>."
    end

    test "a known section with an unknown slug is a real 404", %{conn: conn} do
      conn = get(conn, ~p"/docs/guides/no-such-page")

      assert response(conn, 404)
    end
  end
end
