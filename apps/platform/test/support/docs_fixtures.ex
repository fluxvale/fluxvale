defmodule TestSupport.DocsFixtures do
  @moduledoc false

  # Fixture pages for the docs lane's tests (ADR-0044): build a
  # throwaway content root under tmp/ (gitignored), write pages into
  # its section dirs, and load it through the real Loader. Every
  # loader-writing test restores the real content set via the Loader —
  # persistent_term is global, so these tests are async: false by
  # contract (the blog fixtures' rule).

  alias FluxVale.Docs.Loader

  @doc "A fresh, empty content root under tmp/ (gitignored)."
  @spec content_dir(String.t()) :: Path.t()
  def content_dir(tag) do
    dir =
      Path.join([
        File.cwd!(),
        "tmp",
        "docs-#{tag}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    dir
  end

  @doc "Writes one page file into a section; `lines` is the frontmatter body."
  @spec write_page!(Path.t(), String.t(), String.t(), [String.t()], String.t()) :: :ok
  def write_page!(dir, section, name, lines, body \\ "The body.") do
    frontmatter = Enum.join(lines, "\n")
    section_dir = Path.join(dir, section)
    File.mkdir_p!(section_dir)
    File.write!(Path.join(section_dir, name <> ".md"), "---\n#{frontmatter}\n---\n\n#{body}\n")
    :ok
  end

  @doc "Valid frontmatter for `slug`; extra lines append."
  @spec page_frontmatter(String.t(), [String.t()]) :: [String.t()]
  def page_frontmatter(slug, extra \\ []) do
    [
      "title: Page #{slug}",
      "description: A test page about #{slug}.",
      "order: 10",
      "slug: #{slug}"
      | extra
    ]
  end

  @doc """
  Loads a fixture root and registers the restore of the real content
  set on exit — call from setup when a test module overwrites the docs.
  """
  @spec load_fixtures!(Path.t()) :: :ok
  def load_fixtures!(dir) do
    Loader.load!(dir)

    # Fully qualified — on_exit/1 is ExUnit.Callbacks and only callable
    # from inside a running test process (which is where this helper
    # runs); qualifying avoids importing the callbacks into support.
    ExUnit.Callbacks.on_exit(fn -> Loader.load!() end)
    :ok
  end
end
