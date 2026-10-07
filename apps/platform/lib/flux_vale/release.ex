# Release tasks — the prod image's operator surface (docs/deployment.md
# pipeline, #98). Runs inside the OTP release where Mix is absent: the
# entrypoints are the `bin/migrate` / `bin/seed` wrappers
# (rel/overlays/bin/), which call these through `eval`.
#
# Tested under ExUnit: `with_repo/2` reuses an already-started repo, so
# the suite exercises the real functions against the sandboxed DB — the
# release-only delta (no Mix, standalone repo start) is what can't be
# unit-tested. No `rollback/2`: deployment.md forbids `ecto.rollback`
# outside dev, so the release ships no way to run it.
defmodule FluxVale.Release do
  @moduledoc """
  DB tasks for the production release (`bin/migrate`, `bin/seed`).

  `migrate/0` runs pending Ecto migrations per repo (advisory-locked by
  the migrator — the init container relies on this when pods race) and
  `seed/0` runs the bring-up seed (platform admin + catalog, idempotent).
  """

  @app :flux_vale

  @spec migrate :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _applied, _started} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, Ecto.Migrator.migrations_path(repo), :up, all: true)
        )
    end

    :ok
  end

  @doc """
  Runs the bring-up seed (`FluxVale.Seeds.seed/0`: platform admin +
  catalog). Idempotent, single caller assumed — the admin get-or-create
  is check-then-insert, so overlapping `bin/seed` runs race the identity
  (operator bring-up path, not the advisory-locked init container).
  Per-env FeatureFlag and AccessRule values are AshAdmin-administered,
  never seeded (docs/deployment.md).
  """
  @spec seed :: :ok
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, :ok, _started} = Ecto.Migrator.with_repo(repo, fn _repo -> FluxVale.Seeds.seed() end)
    end

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
