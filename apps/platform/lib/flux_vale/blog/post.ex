defmodule FluxVale.Blog.Post do
  @moduledoc """
  One compiled blog post (ADR-00025 §1): frontmatter fields plus the
  boot-time render products — HTML (mdex, rendered once at load) and
  reading minutes. Built by `FluxVale.Blog.Loader`; consumers read it
  through `FluxVale.Blog`.
  """

  @enforce_keys [
    :title,
    :description,
    :date,
    :slug,
    :author,
    :draft,
    :og_image,
    :tags,
    :html,
    :reading_minutes,
    :source_path
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          title: String.t(),
          description: String.t(),
          date: Date.t(),
          slug: String.t(),
          author: String.t(),
          draft: boolean(),
          og_image: String.t() | nil,
          tags: [String.t()],
          html: String.t(),
          reading_minutes: pos_integer(),
          source_path: Path.t()
        }
end
