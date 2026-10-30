defmodule TestSupport.BlogFixtures do
  @moduledoc false

  # Fixture posts for the blog lane's tests: build a throwaway content
  # directory under tmp/ (gitignored), write posts into it, and load it
  # through the real Loader. Every loader-writing test restores the real
  # content set via load_fixtures!/1 — persistent_term is global, so
  # these tests are async: false by contract.

  alias FluxVale.Blog.Loader

  @doc "A fresh, empty content dir under tmp/ (gitignored)."
  @spec post_dir(String.t()) :: Path.t()
  def post_dir(tag) do
    dir =
      Path.join([
        File.cwd!(),
        "tmp",
        "blog-#{tag}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    dir
  end

  @doc "Writes one post file; `lines` is the frontmatter body."
  @spec write_post!(Path.t(), String.t(), [String.t()], String.t()) :: :ok
  def write_post!(dir, name, lines, body \\ "The body.") do
    frontmatter = Enum.join(lines, "\n")
    File.write!(Path.join(dir, name <> ".md"), "---\n#{frontmatter}\n---\n\n#{body}\n")
    :ok
  end

  @doc "Valid frontmatter for `slug`; extra lines append (draft, tags…)."
  @spec post_frontmatter(String.t(), [String.t()]) :: [String.t()]
  def post_frontmatter(slug, extra \\ []) do
    [
      "title: Post #{slug}",
      "description: A test post about #{slug}.",
      "date: 2026-10-31",
      "slug: #{slug}",
      "author: Tester"
      | extra
    ]
  end

  @doc """
  Loads a fixture dir and registers the restore of the real content set
  on exit — call from setup when a test module overwrites the blog.
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
