defmodule FluxVale.Docs.Lint do
  @moduledoc """
  The public-docs content lint (ADR-0044 §4). Two jobs:

  - **Boundary**: every regular file under the content root must be a
    `.md` page living directly inside a known section directory
    (`FluxVale.Docs.Sections.keys/0`). Root-level files, nested
    directories, non-markdown files, and unknown sections all fail.
    Only `docs/public` ever rides the sync into priv (ADR-0044 §6),
    and nothing stray can ride inside it either.
  - **Frontmatter**: parseable YAML with the required fields
    (`title`, `description`, `order`, `slug`), types checked, the slug
    equal to its filename stem and lowercase-hyphenated, unknown
    fields rejected — the blog lint's rules (ADR-00025 §1) adapted to
    evergreen pages (an `order`, not a date).

  `mix docs.lint` (in `mix ci`) is the caller against the SOURCE tree;
  `FluxVale.Docs.Loader.load!/1` re-checks the synced priv copy at
  boot so invalid content cannot deploy either.
  """

  alias FluxVale.Docs.Sections
  alias FluxVale.Markdown

  @known_fields ~w(title description order slug)
  @required_fields ~w(title description order slug)
  @string_fields ~w(title description slug)
  @slug_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @doc """
  Lints a content root: boundary shape plus per-page frontmatter.
  `:ok` or every failure, one message each, prefixed with the file it
  came from.

  No cross-file duplicate-slug rule: a page's `slug` must equal its
  filename stem and pages live in per-section directories, so the
  routing pair {section, slug} cannot collide without failing the
  stem rule.
  """
  @spec check(Path.t()) :: :ok | {:error, [String.t()]}
  def check(dir) do
    paths = file_paths(dir)
    errors = boundary_errors(dir) ++ Enum.flat_map(paths, &file_errors(&1, dir))

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  The known-section `*.md` files of a content root, sorted — one
  stable page set for lint, compile, and the reload stamp. Files the
  boundary rule reports are excluded here (they are errors, not
  pages).
  """
  @spec file_paths(Path.t()) :: [Path.t()]
  def file_paths(dir) do
    dir
    |> Path.join("*/*.md")
    |> Path.wildcard()
    |> Enum.filter(&section_page?/1)
    |> Enum.sort()
  end

  # ---- Boundary ----

  # match_dot: true — editor droppings (.DS_Store, .hidden/) are
  # invisible to the default glob and would ride the sync into priv
  # unnoticed; the boundary must SEE them, even though they can never
  # serve (the page glob in file_paths keeps excluding them).
  defp boundary_errors(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.flat_map(&entry_errors(&1, dir))
  end

  defp entry_errors(path, dir) do
    rel = Path.relative_to(path, dir)

    if File.dir?(path) do
      directory_errors(rel)
    else
      file_boundary_errors(path, rel)
    end
  end

  # Directories: exactly the known section dirs at depth one — a
  # stray, nested, or empty directory is a boundary failure even with
  # no file inside it (ADR-0044 §4's "no nested directories, no
  # unknown sections" covers the tree, not just its files).
  defp directory_errors(rel) do
    sections = Enum.join(Sections.keys(), ", ")

    if rel in Sections.keys() do
      []
    else
      [
        "#{rel}: unexpected directory — docs trees are <section>/<slug>.md under a known section (#{sections})"
      ]
    end
  end

  defp file_boundary_errors(path, rel) do
    sections = Enum.join(Sections.keys(), ", ")

    if section_page?(path) do
      []
    else
      ["#{rel}: docs pages are <section>/<slug>.md under a known section (#{sections})"]
    end
  end

  defp section_page?(path) do
    parts = Path.split(path)
    [section, file] = Enum.take(parts, -2)

    section in Sections.keys() and Path.extname(file) == ".md"
  end

  # ---- Frontmatter ----

  # The file prefix is the path relative to the content root (unlike
  # the blog's basename): pages share basenames across sections, so
  # "guides/sizes.md" is the name an author can act on.
  defp file_errors(path, dir) do
    prefix = Path.relative_to(path, dir)
    stem = Path.basename(path, ".md")

    case Markdown.parse_file(path) do
      {:error, reason} ->
        ["#{prefix}: #{reason}"]

      {:ok, attrs, _body} ->
        errors =
          required_field_errors(attrs) ++
            string_field_errors(attrs) ++
            order_errors(attrs) ++
            slug_errors(attrs, stem) ++
            unknown_field_errors(attrs)

        if errors == [] do
          []
        else
          Enum.map(errors, &"#{prefix}: #{&1}")
        end
    end
  end

  defp required_field_errors(attrs) do
    for field <- @required_fields,
        blank?(attrs[field]) do
      "missing required field \"#{field}\""
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp string_field_errors(attrs) do
    for field <- @string_fields,
        Map.has_key?(attrs, field),
        not is_binary(attrs[field]) do
      "\"#{field}\" must be a string"
    end
  end

  # yaml_elixir hands integers over as integers; a missing order is
  # already the required-field rule's error, so the nil arm stays quiet.
  defp order_errors(attrs) do
    case attrs["order"] do
      nil -> []
      order when is_integer(order) -> []
      _other -> ["\"order\" must be an integer"]
    end
  end

  defp slug_errors(attrs, stem) do
    case attrs["slug"] do
      nil ->
        []

      slug when is_binary(slug) ->
        slug_format_errors(slug, stem)

      _other ->
        ["\"slug\" must be a string"]
    end
  end

  defp slug_format_errors(slug, stem) do
    cond do
      not (slug =~ @slug_format) ->
        ["\"slug\" must be lowercase words joined by single hyphens (#{slug})"]

      slug != stem ->
        ["\"slug\" (#{slug}) must equal the filename stem (#{stem})"]

      true ->
        []
    end
  end

  defp unknown_field_errors(attrs) do
    unknown = for key <- Map.keys(attrs), key not in @known_fields, do: key

    if unknown == [] do
      []
    else
      names =
        unknown
        |> Enum.sort()
        |> Enum.join(", ")

      allowed = Enum.join(@known_fields, ", ")
      ["unknown field(s) #{names} — allowed: #{allowed}"]
    end
  end
end
