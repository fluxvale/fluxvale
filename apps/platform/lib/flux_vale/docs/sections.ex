defmodule FluxVale.Docs.Sections do
  @moduledoc """
  The public docs' fixed section list (ADR-0044 §1): the directories
  under `docs/public/`, in sidebar order, with the display copy the
  index page, section pages, and sidebar render. `FluxVale.Docs.Lint`
  validates the content tree against `keys/0` — a new section is a
  deliberate code change here, never a stray directory in the tree.
  """

  @type section :: %{key: String.t(), title: String.t(), description: String.t()}

  @sections [
    %{
      key: "getting-started",
      title: "Getting started",
      description: "From invitation to your first running app."
    },
    %{
      key: "guides",
      title: "Guides",
      description: "How the platform works, feature by feature."
    },
    %{
      key: "automation",
      title: "Automation",
      description: "Drive FluxVale from the terminal and from infrastructure code."
    },
    %{
      key: "help",
      title: "Help",
      description: "Answers to common questions, and where to reach us."
    }
  ]

  @doc "The sections in sidebar order."
  @spec sections() :: [section()]
  def sections, do: @sections

  @doc "The section keys — the allowed directories under the content root."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@sections, & &1.key)

  @doc "One section by key; `nil` when unknown."
  @spec get(String.t()) :: section() | nil
  def get(key), do: Enum.find(@sections, &(&1.key == key))
end
