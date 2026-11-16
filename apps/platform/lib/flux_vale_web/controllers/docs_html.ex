defmodule FluxValeWeb.DocsHTML do
  @moduledoc """
  Templates for the public docs' SSR pages (ADR-0044 §5), plus the
  sectioned sidebar the section and page templates share.
  """

  use FluxValeWeb, :html

  embed_templates("docs_html/*")

  # The sectioned sidebar (ADR-0044 §5): plain links, the active mark
  # via class + aria-current, no JS (the blog's content-link idiom).
  # Section headings link the section page; page links carry the
  # section prefix in their URL.
  attr(:sections, :list,
    required: true,
    doc: "the section/page tree, from FluxVale.Docs.sections_with_pages/0"
  )

  attr(:active_section, :string, default: nil, doc: "the section key to mark active")
  attr(:active_slug, :string, default: nil, doc: "the page slug to mark active")

  attr(:active_agent_docs, :boolean,
    default: false,
    doc: "marks the agent guide's fixed entry active"
  )

  def sidebar(assigns) do
    ~H"""
    <nav class="docs-nav" aria-label="Documentation">
      <%!-- #799: the agent guide is a page, not a content section — a
      fixed top-level entry above the section map, the index page's
      placement. --%>
      <div class="docs-nav-section">
        <ul class="docs-nav-list">
          <li>
            <a
              href={~p"/docs/agents"}
              class={["docs-nav-link", @active_agent_docs && "docs-nav-link-active"]}
              aria-current={if(@active_agent_docs, do: "page")}
            >
              Set up with your agent
            </a>
          </li>
        </ul>
      </div>
      <div :for={{section, pages} <- @sections} class="docs-nav-section">
        <p class="docs-nav-heading">
          <a href={~p"/docs/#{section.key}"} class="docs-nav-section-link">
            {section.title}
          </a>
        </p>
        <ul class="docs-nav-list">
          <li :for={page <- pages}>
            <a
              href={~p"/docs/#{section.key}/#{page.slug}"}
              class={[
                "docs-nav-link",
                @active_section == section.key && @active_slug == page.slug &&
                  "docs-nav-link-active"
              ]}
              aria-current={
                if(@active_section == section.key && @active_slug == page.slug, do: "page")
              }
            >
              {page.title}
            </a>
          </li>
        </ul>
      </div>
    </nav>
    """
  end
end
