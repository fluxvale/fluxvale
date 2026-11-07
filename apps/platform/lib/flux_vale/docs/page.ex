defmodule FluxVale.Docs.Page do
  @moduledoc """
  One compiled public docs page (ADR-0044 §3): frontmatter fields plus
  the boot-time render product. Built by `FluxVale.Docs.Loader`;
  consumers read it through `FluxVale.Docs`.
  """

  @enforce_keys [:title, :description, :order, :slug, :section, :html, :source_path]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          title: String.t(),
          description: String.t(),
          order: integer(),
          slug: String.t(),
          section: String.t(),
          html: String.t(),
          source_path: Path.t()
        }
end
