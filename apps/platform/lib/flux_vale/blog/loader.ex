defmodule FluxVale.Blog.Loader do
  @moduledoc """
  The boot-time compile (ADR-00025 §1): lint, render, publish. Reads
  `priv/content/blog/*.md`, renders each body once through mdex
  (CommonMark + GFM tables/strikethrough/tasklist/autolink — no
  client-side highlighting, no raw HTML), and publishes the post set
  to `:persistent_term` — per-request cost is a term lookup, a deploy
  publishes (posts are files inside the release).

  Invalid content fails the load loudly (CI's `mix blog.lint` catches
  it first; boot is the backstop). Dev hot-reload rides
  `reload_if_changed!/0` — `FluxVale.Blog.maybe_hot_reload/0` gates it.
  """

  alias FluxVale.Blog.Lint
  alias FluxVale.Blog.Post

  alias MDEx

  @posts_key {__MODULE__, :posts}
  @stamp_key {__MODULE__, :stamp}

  @words_per_minute 200

  @doc """
  Lints and compiles a content directory and publishes it to
  persistent_term. Raises `ArgumentError` on lint failure — a bad post
  stops the boot, never serves half-parsed.
  """
  @spec load!(Path.t() | nil) :: :ok
  def load!(dir \\ nil) do
    dir = dir || default_dir()

    case Lint.check(dir) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ArgumentError, "blog content failed lint:\n" <> Enum.join(errors, "\n")
    end

    posts = compile(dir)

    :persistent_term.put(@posts_key, posts)
    :persistent_term.put(@stamp_key, stamp(dir))
    :ok
  end

  @doc "The published post set (newest first) — the zero-cost read."
  @spec loaded() :: [Post.t()]
  def loaded, do: :persistent_term.get(@posts_key, [])

  @doc """
  Dev hot reload: stat-stamps a content directory and recompiles only
  when something changed (edit, add, remove). Raises through `load!/1`
  when the new content is invalid.
  """
  @spec reload_if_changed!(Path.t() | nil) :: :ok
  def reload_if_changed!(dir \\ nil) do
    dir = dir || default_dir()
    current = :persistent_term.get(@stamp_key, nil)

    if stamp(dir) != current do
      load!(dir)
    else
      :ok
    end
  end

  @doc "The content dir this release carries (ADR-00025 §1's path)."
  @spec default_dir() :: Path.t()
  def default_dir, do: Application.app_dir(:flux_vale, "priv/content/blog")

  defp compile(dir) do
    dir
    |> Lint.file_paths()
    |> Enum.map(fn path ->
      {:ok, attrs, body} = Lint.parse(path)
      build_post(path, attrs, body)
    end)
    |> Enum.sort_by(& &1.date, {:desc, Date})
  end

  defp build_post(path, attrs, body) do
    %Post{
      title: attrs["title"],
      description: attrs["description"],
      date: normalize_date(attrs["date"]),
      slug: attrs["slug"],
      author: attrs["author"],
      draft: attrs["draft"] || false,
      og_image: attrs["og_image"],
      tags: attrs["tags"] || [],
      html: render(body),
      reading_minutes: reading_minutes(body),
      source_path: path
    }
  end

  defp render(body) do
    MDEx.to_html!(body,
      extension: [table: true, strikethrough: true, tasklist: true, autolink: true]
    )
  end

  # yaml_elixir hands dates over as ISO strings (probed — quoted or
  # not), and the lint already guaranteed parseability by the time the
  # loader runs, so the bang parse cannot miss here.
  defp normalize_date(iso_date) when is_binary(iso_date) do
    {:ok, date} = Date.from_iso8601(iso_date)
    date
  end

  defp reading_minutes(body) do
    words =
      body
      |> String.split()
      |> length()

    max(1, ceil(words / @words_per_minute))
  end

  # The reload stamp: per file, name + size + mtime — any edit, add, or
  # remove changes the list; identical trees are identical terms.
  defp stamp(dir) do
    for path <- Lint.file_paths(dir) do
      stat = File.stat!(path)
      {Path.basename(path), stat.size, stat.mtime}
    end
  end
end
