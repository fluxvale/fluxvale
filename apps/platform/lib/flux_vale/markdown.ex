defmodule FluxVale.Markdown do
  @moduledoc """
  Shared markdown mechanics for the two content lanes — the blog
  (ADR-00025 §1) and the public docs (ADR-0044): the frontmatter split
  (a YAML mapping block delimited by `---` lines) and the one mdex
  render configuration both loaders render bodies with. One markdown
  grammar, two content trees — the lanes differ in shape rules (lint),
  never in markdown.
  """

  alias MDEx

  @doc """
  Splits one markdown file into its frontmatter map (string keys, raw
  YAML values) and the markdown body. `{:error, reason}` for a missing
  or malformed frontmatter block or invalid YAML.
  """
  @spec parse_file(Path.t()) ::
          {:ok, %{required(String.t()) => term()}, String.t()} | {:error, String.t()}
  def parse_file(path) do
    path
    |> File.read!()
    |> parse()
  end

  @doc """
  Splits markdown contents into frontmatter and body. `{:error,
  reason}` for a missing or malformed frontmatter block or invalid
  YAML.
  """
  @spec parse(String.t()) ::
          {:ok, %{required(String.t()) => term()}, String.t()} | {:error, String.t()}
  def parse("---" <> rest = contents) do
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

  def parse(_not_delimited) do
    {:error, "missing frontmatter (must open with a --- block)"}
  end

  @doc """
  Renders a markdown body to HTML once, at load: CommonMark + GFM
  tables/strikethrough/tasklist/autolink — comrak's safe default (raw
  HTML in bodies never reaches the DOM), no client-side highlighting.
  """
  @spec render(String.t()) :: String.t()
  def render(body) do
    MDEx.to_html!(body,
      extension: [table: true, strikethrough: true, tasklist: true, autolink: true]
    )
  end
end
