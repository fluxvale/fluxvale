defmodule Mix.Tasks.FluxVale.OpenApi do
  @shortdoc "Dumps the /api/v1 OpenAPI spec to priv/open_api.json"

  @moduledoc """
  Writes the committed OpenAPI artifact for `/api/v1`
  (`apps/platform/priv/open_api.json`): the spec rendered offline from
  compiled Ash resources — no server, no Repo (ADR-0019 §2) — by the
  same render `GET /api/v1/open_api` serves (modulo the
  endpoint-derived `servers` entry, which stays empty offline). A
  build input for CLI client generation, not a public doc.

      mix flux_vale.open_api              # write the artifact
      mix flux_vale.open_api --check      # exit 1 while stale
      mix flux_vale.open_api PATH         # write elsewhere

  A route added without re-dumping fails `mix ci` — the staleness
  test asserts the same render-equals-artifact equality `--check`
  makes.
  """

  use Mix.Task

  alias FluxVale.Api.OpenApiDump

  @requirements ["app.config"]

  @switches [check: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] ->
        {flag, _value} = List.first(invalid)

        # A typo'd --chek would silently WRITE instead of check — refuse.
        Mix.shell().error("unknown flag #{flag} (only --check is understood)")
        exit({:shutdown, 1})

      length(positional) > 1 ->
        # A second PATH would be silently dropped — same refusal class
        # as the typo'd flag above.
        Mix.shell().error(
          "unexpected extra argument (usage: mix flux_vale.open_api [PATH] --check)"
        )

        exit({:shutdown, 1})

      true ->
        :ok
    end

    path = List.first(positional) || OpenApiDump.default_path()

    if opts[:check] do
      check(path)
    else
      write(path)
    end
  end

  defp write(path) do
    File.write!(path, OpenApiDump.render())
    Mix.shell().info("wrote #{path}")
  end

  defp check(path) do
    rendered = OpenApiDump.render()

    case File.read(path) do
      {:ok, ^rendered} ->
        Mix.shell().info("open_api.json up to date")

      {:ok, _stale} ->
        Mix.shell().error("#{path} is stale — run `mix flux_vale.open_api` and commit it")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("cannot read #{path}: #{:file.format_error(reason)}")
        exit({:shutdown, 1})
    end
  end
end
