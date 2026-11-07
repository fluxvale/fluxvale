defmodule FluxVale.Docs.Loader do
  @moduledoc """
  The boot-time compile (ADR-0044 §3): lint, render, publish — the
  blog loader's semantics (ADR-00025 §1) for the docs tree. Reads
  `priv/content/docs/<section>/<slug>.md` (the synced copy of
  `docs/public`), renders each body once through `FluxVale.Markdown`,
  and publishes the page set to `:persistent_term` — per-request cost
  is a term lookup, a deploy publishes.

  Invalid content fails the load loudly (CI's `mix docs.lint` catches
  the source tree first; boot is the backstop on the priv copy). Dev
  hot reload rides `reload_if_changed!/0` —
  `FluxVale.Docs.maybe_hot_reload/0` gates it.
  """

  alias FluxVale.Docs.Lint
  alias FluxVale.Docs.Page
  alias FluxVale.Docs.Sections
  alias FluxVale.Markdown

  @pages_key {__MODULE__, :pages}
  @stamp_key {__MODULE__, :stamp}

  @doc """
  Lints and compiles a content directory and publishes it to
  persistent_term. Raises `ArgumentError` on lint failure — a bad
  page stops the boot, never serves half-parsed. A missing content
  root also raises (ADR-0044 §2 made the tree sync-generated: a
  silent empty boot would serve a content-less /docs with no trace).
  """
  @spec load!(Path.t() | nil) :: :ok
  def load!(dir \\ nil) do
    dir = dir || default_dir()

    ensure_content_root!(dir)

    case Lint.check(dir) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ArgumentError, "docs content failed lint:\n" <> Enum.join(errors, "\n")
    end

    pages = compile(dir)

    :persistent_term.put(@pages_key, pages)
    :persistent_term.put(@stamp_key, stamp(dir))
    :ok
  end

  @doc "The published page set (section order, then page order) — the zero-cost read."
  @spec loaded() :: [Page.t()]
  def loaded, do: :persistent_term.get(@pages_key, [])

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

  @doc "The content dir this release carries (ADR-0044 §2's synced path)."
  @spec default_dir() :: Path.t()
  def default_dir, do: Application.app_dir(:flux_vale, "priv/content/docs")

  defp compile(dir) do
    dir
    |> Lint.file_paths()
    |> Enum.map(fn path ->
      {:ok, attrs, body} = Markdown.parse_file(path)
      build_page(path, attrs, body)
    end)
    |> sort_pages()
  end

  # The sync made the tree build-generated (ADR-0044 §2) — a missing
  # root is "the sync never ran", which must stop the boot loudly
  # instead of serving a content-less surface (the sync script's own
  # stance, mirrored at the loader backstop).
  defp ensure_content_root!(dir) do
    unless File.dir?(dir) do
      raise ArgumentError,
            "docs content directory missing: #{dir} (run mix content.sync — ADR-0044 §2)"
    end
  end

  defp build_page(path, attrs, body) do
    %Page{
      title: attrs["title"],
      description: attrs["description"],
      order: attrs["order"],
      slug: attrs["slug"],
      section: section_of(path),
      html: Markdown.render(body),
      source_path: path
    }
  end

  defp section_of(path) do
    parts = Path.split(path)
    [section, _file] = Enum.take(parts, -2)
    section
  end

  # Section order first (Sections defines it), then the page's own
  # order, then slug — a stable, predictable sidebar and index.
  defp sort_pages(pages) do
    keys = Sections.keys()

    section_order =
      keys
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(pages, fn page ->
      {Map.fetch!(section_order, page.section), page.order, page.slug}
    end)
  end

  # The reload stamp: per file, section-relative path + size + mtime —
  # any edit, add, or remove changes the list; identical trees are
  # identical terms.
  defp stamp(dir) do
    for path <- Lint.file_paths(dir) do
      stat = File.stat!(path)
      {Path.relative_to(path, dir), stat.size, stat.mtime}
    end
  end
end
