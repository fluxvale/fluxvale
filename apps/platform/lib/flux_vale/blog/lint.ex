defmodule FluxVale.Blog.Lint do
  @moduledoc """
  The content lint (ADR-00025 §1: "a mix task validates frontmatter so
  agent-authored posts fail CI loudly"): every `*.md` under
  `priv/content/blog` must carry parseable YAML frontmatter with the
  required fields; a post's slug equals its filename stem; slugs are
  unique; an `og_image` must resolve to a shipped static file. `mix
  blog.lint` (in `mix ci`) is the caller — invalid content cannot
  merge, and `FluxVale.Blog.Loader.load!/1` re-checks at boot so it
  cannot deploy either.

  This module also owns frontmatter parsing (the split + YAML read) —
  the Loader depends on it, never the other way around.
  """

  @known_fields ~w(title description date slug author draft og_image tags)
  @required_fields ~w(title description date slug author)
  @string_fields ~w(title description slug author)
  @slug_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @doc """
  Lints a content directory: frontmatter present and well-formed with
  the required fields, slug equal to the filename stem, `og_image`
  resolving to a shipped static file. `:ok` or every failure, one
  message each, prefixed with the file it came from.

  No cross-file duplicate-slug rule: `slug` must equal the filename
  stem, so two files sharing a slug necessarily fail that rule in at
  least one of them — a duplicate can never pass this lint.
  """
  @spec check(Path.t()) :: :ok | {:error, [String.t()]}
  def check(dir) do
    static_root = Application.app_dir(:flux_vale, "priv/static")
    paths = file_paths(dir)

    file_errors = validate_files(paths, static_root)

    if file_errors == [], do: :ok, else: {:error, file_errors}
  end

  @doc """
  The `*.md` files of a content directory, sorted — one stable post
  order for lint, compile, and the reload stamp.
  """
  @spec file_paths(Path.t()) :: [Path.t()]
  def file_paths(dir) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc """
  Splits one post file into its frontmatter map (string keys, raw YAML
  values) and the markdown body. `{:error, reason}` for a missing or
  malformed frontmatter block or invalid YAML.
  """
  @spec parse(Path.t()) ::
          {:ok, %{required(String.t()) => term()}, String.t()} | {:error, String.t()}
  def parse(path) do
    path
    |> File.read!()
    |> parse_contents()
  end

  defp parse_contents("---" <> rest = contents) do
    case String.split(rest, ["\n---\n", "\n---\r\n", "\n---"], parts: 2) do
      [frontmatter, body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, attrs} when is_map(attrs) -> {:ok, attrs, body}
          {:ok, _other} -> {:error, "frontmatter must be a YAML mapping"}
          {:error, error} -> {:error, "invalid YAML frontmatter: #{Exception.message(error)}"}
        end

      _no_closing_delimiter ->
        {:error, "missing closing --- delimiter (#{inspect(String.slice(contents, 0, 20))}…)"}
    end
  end

  defp parse_contents(_not_delimited) do
    {:error, "missing frontmatter (must open with a --- block)"}
  end

  defp validate_files(paths, static_root) do
    Enum.reduce(paths, [], fn path, errors ->
      case validate_file(path, static_root) do
        {:ok, _attrs} -> errors
        {:error, file_errors} -> errors ++ file_errors
      end
    end)
  end

  defp validate_file(path, static_root) do
    stem = Path.basename(path, ".md")

    case parse(path) do
      {:error, reason} ->
        {:error, ["#{Path.basename(path)}: #{reason}"]}

      {:ok, attrs, _body} ->
        errors =
          required_field_errors(attrs) ++
            string_field_errors(attrs) ++
            date_errors(attrs) ++
            slug_errors(attrs, stem) ++
            boolean_field_errors(attrs) ++
            og_image_errors(attrs, static_root) ++
            tags_errors(attrs) ++
            unknown_field_errors(attrs)

        if errors == [] do
          {:ok, attrs}
        else
          {:error, Enum.map(errors, &"#{Path.basename(path)}: #{&1}")}
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

  defp date_errors(attrs) do
    case attrs["date"] do
      nil ->
        []

      value when is_binary(value) ->
        iso_date_errors(value)

      _other ->
        ["\"date\" must be a YYYY-MM-DD date"]
    end
  end

  # yaml_elixir returns dates as strings (quoted or not — probed), so
  # the lint sees binaries only; anything else is a type error above.
  defp iso_date_errors(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{}} -> []
      {:error, _reason} -> ["\"date\" must be a YYYY-MM-DD date"]
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

  defp boolean_field_errors(attrs) do
    case attrs["draft"] do
      nil -> []
      true -> []
      false -> []
      _other -> ["\"draft\" must be a boolean"]
    end
  end

  defp og_image_errors(attrs, static_root) do
    case attrs["og_image"] do
      nil ->
        []

      path when is_binary(path) ->
        resolved = Path.join(static_root, path)

        cond do
          not String.starts_with?(path, "/") ->
            ["\"og_image\" must be an app-absolute path like /images/x.png (#{path})"]

          not File.exists?(resolved) ->
            ["\"og_image\" does not resolve to a shipped static file (#{path})"]

          true ->
            []
        end

      _other ->
        ["\"og_image\" must be a string"]
    end
  end

  defp tags_errors(attrs) do
    case attrs["tags"] do
      nil ->
        []

      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1) do
          []
        else
          ["\"tags\" must be a list of strings"]
        end

      _other ->
        ["\"tags\" must be a list of strings"]
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
