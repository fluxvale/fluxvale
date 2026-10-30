defmodule Mix.Tasks.Blog.Lint do
  @shortdoc "Validates blog post frontmatter (ADR-00025)"

  @moduledoc """
  Validates the blog content directory (`priv/content/blog`): every
  post's frontmatter parses and carries the required fields, slugs
  equal their filename stems, `og_image` paths resolve to shipped
  static files. Runs in `mix ci` (ADR-00025 §1: agent-authored posts
  fail CI loudly); `FluxVale.Blog.Loader.load!/1` re-checks at boot.

  An optional argument lints another directory (the tests' fixture
  dirs ride it). A failing lint exits 1 with one message per problem.
  """

  use Mix.Task

  alias FluxVale.Blog.Lint
  alias FluxVale.Blog.Loader

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    dir = List.first(args) || Loader.default_dir()

    case Lint.check(dir) do
      :ok ->
        Mix.shell().info("blog content ok")

      {:error, errors} ->
        Enum.each(errors, &Mix.shell().error(&1))
        Mix.shell().error("mix blog.lint failed")
        exit({:shutdown, 1})
    end
  end
end
