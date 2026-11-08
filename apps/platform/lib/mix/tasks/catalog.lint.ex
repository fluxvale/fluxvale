defmodule Mix.Tasks.Catalog.Lint do
  @shortdoc "Reports catalog curation completeness (#611)"

  @moduledoc """
  Reports which curation tier each seeded app reaches (#611 plan §5:
  minimum, recommended, full parity) and what is missing. Informational
  in v1 — it exits 0 whatever the report says (D1: omission is a
  designed state, never a CI failure). Malformed content fails at seed
  time through the types, not here.
  """

  use Mix.Task

  alias FluxVale.Catalog.Lint
  alias FluxVale.Seeds.CatalogData

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    report = Lint.report(CatalogData.entries())
    Enum.each(report, &Mix.shell().info(&1))
  end
end
