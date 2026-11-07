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

      # The footer carries the docs link on every public page (ADR-0044 §5).
      assert html =~ ~s(data-testid="footer-docs")
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

      # The body is rendered markdown, not raw source.
      assert html =~ "The <strong>body</strong>."
    end

    test "a known section with an unknown slug is a real 404", %{conn: conn} do
      conn = get(conn, ~p"/docs/guides/no-such-page")

      assert response(conn, 404)
    end
  end
end
