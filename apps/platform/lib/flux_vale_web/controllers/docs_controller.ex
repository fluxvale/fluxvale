defmodule FluxValeWeb.DocsController do
  @moduledoc """
  The public docs' SSR surface (ADR-0044 §5): `/docs`,
  `/docs/:section`, `/docs/:section/:slug` — plain controller+HEEx
  like the blog (ADR-00025 §1), so crawlers get the full document with
  zero JS. Pages come boot-compiled from `FluxVale.Docs`
  (persistent_term reads); the sectioned sidebar rides the section
  and page templates as plain HTML. Unknown sections and slugs are
  real 404s — and a section with no pages is "not here", so a future
  section ships with its first page, never as an empty shell.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Docs
  alias FluxVale.Docs.Page
  alias FluxVale.Docs.Sections

  @docs_description "Guides and answers for running your apps on FluxVale"

  def index(conn, _params) do
    Docs.maybe_hot_reload()

    conn
    |> assign(:page_title, "Docs · FluxVale")
    |> assign(:page_description, @docs_description)
    |> assign(:canonical_path, "/docs")
    |> assign(:sections, Docs.sections_with_pages())
    |> render(:index)
  end

  def section(conn, %{"section" => key}) do
    Docs.maybe_hot_reload()

    sections = Docs.sections_with_pages()

    case Enum.find(sections, fn {section, _pages} -> section.key == key end) do
      nil ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: FluxValeWeb.Router

      {section, pages} ->
        conn
        |> assign(:page_title, "#{section.title} · FluxVale Docs")
        |> assign(:page_description, section.description)
        |> assign(:canonical_path, "/docs/#{section.key}")
        |> assign(:sections, sections)
        |> assign(:section, section)
        |> assign(:pages, pages)
        |> render(:section)
    end
  end

  def show(conn, %{"section" => key, "slug" => slug}) do
    Docs.maybe_hot_reload()

    case Docs.get(key, slug) do
      nil ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: FluxValeWeb.Router

      %Page{} = page ->
        conn
        |> assign(:page_title, "#{page.title} · FluxVale Docs")
        |> assign(:page_description, page.description)
        |> assign(:canonical_path, "/docs/#{page.section}/#{page.slug}")
        |> assign(:sections, Docs.sections_with_pages())
        |> assign(:section, Sections.get(page.section))
        |> assign(:page, page)
        |> render(:show)
    end
  end
end
