defmodule FluxVale.Docs do
  @moduledoc """
  The public docs' seam (ADR-0044 §3): boot-compiled markdown pages
  served as server-rendered HTML at `/docs` — no LiveView, zero client
  JS, the rendering stance of the blog (ADR-00025 §1) applied to
  evergreen pages. Reads are persistent_term lookups. Web-layer
  callers use this module, never the Loader/Lint internals.
  """

  alias FluxVale.Docs.Loader
  alias FluxVale.Docs.Page
  alias FluxVale.Docs.Sections

  @doc "Every loaded page, section order then page order."
  @spec all_pages() :: [Page.t()]
  def all_pages, do: Loader.loaded()

  @doc """
  Sections that carry pages, in sidebar order, each with its pages —
  the index page's and the sidebar's shape. A section with no pages
  does not render: nothing to link to, no dead section page.
  """
  @spec sections_with_pages() :: [{Sections.section(), [Page.t()]}]
  def sections_with_pages do
    Sections.sections()
    |> Enum.map(fn section -> {section, pages(section.key)} end)
    |> Enum.reject(fn {_section, section_pages} -> section_pages == [] end)
  end

  @doc "One section's pages, ordered; `[]` when the section has none."
  @spec pages(String.t()) :: [Page.t()]
  def pages(section_key),
    do: Enum.filter(all_pages(), &(&1.section == section_key))

  @doc "One page by section key and slug; `nil` when absent."
  @spec get(String.t(), String.t()) :: Page.t() | nil
  def get(section_key, slug) do
    section_pages = pages(section_key)
    Enum.find(section_pages, &(&1.slug == slug))
  end

  @doc """
  Dev-only hot reload (`docs_hot_reload: true` in dev.exs): the blog
  seam's semantics verbatim for the docs tree — stat-check the content
  dir and recompile when it changed, so editing a page locally needs
  no restart. The flag is unset in test/prod — a no-op there.
  """
  @spec maybe_hot_reload() :: :ok
  def maybe_hot_reload do
    if Application.get_env(:flux_vale, :docs_hot_reload, false) do
      Loader.reload_if_changed!()
    else
      :ok
    end
  end
end
