defmodule FluxVale.Repo.Migrations.AddObanJobsTable do
  @moduledoc """
  Adds the Oban job queue table (#23).

  `Oban.Migrations.up/0` is version-aware: it applies the schema versions
  new to this Oban (2.23) and is idempotent across future Oban bumps —
  rerunning it as a fresh migration only adds then-missing versions.
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up()

  def down, do: Oban.Migrations.down()
end
