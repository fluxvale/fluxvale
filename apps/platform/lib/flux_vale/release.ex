# Release tasks — the prod image's operator surface (docs/deployment.md
# pipeline, #98). Runs inside the OTP release where Mix is absent: the
# entrypoints are the `bin/migrate` / `bin/seed` / `bin/ensure-cluster`
# wrappers (rel/overlays/bin/), which call these through `eval`.
#
# Tested under ExUnit: `with_repo/2` reuses an already-started repo, so
# the suite exercises the real functions against the sandboxed DB — the
# release-only delta (no Mix, standalone repo start) is what can't be
# unit-tested. No `rollback/2`: deployment.md forbids `ecto.rollback`
# outside dev, so the release ships no way to run it.
defmodule FluxVale.Release do
  @moduledoc """
  Operator tasks for the production release (`bin/migrate`, `bin/seed`,
  `bin/owner-signin`, `bin/ensure-cluster`).

  `migrate/0` runs pending Ecto migrations per repo (advisory-locked by
  the migrator — the init container relies on this when pods race),
  `seed/0` runs the bring-up seed (platform admin + catalog, idempotent)
  and `ensure_cluster/0` get-or-creates this environment's Cluster row
  (#155).
  """

  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Ops.OwnerSignIn

  require Logger

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

  @doc """
  Get-or-creates this environment's Cluster row (`bin/ensure-cluster`,
  #155): `CLUSTER_NAME` names it and `kubeconfig_ref` stays NULL — the
  in-cluster service-account sentinel (ADR-0006 Am. 2). Instance create
  needs exactly one Cluster row (`ResolveCluster` refuses zero or many),
  so the row must exist before the first instance. Get-or-create, never
  converge: an admin-set ref is deliberate drift, same posture as
  `FluxVale.Seeds.seed_local_cluster!/0`.

  A re-run under a different `CLUSTER_NAME` than the row already present
  raises instead of adding a second row — two rows break `ResolveCluster`
  and every instance create until one is removed.
  """
  @spec ensure_cluster :: :ok
  def ensure_cluster do
    load_app()

    case System.get_env("CLUSTER_NAME") do
      name when name in [nil, ""] ->
        raise ArgumentError,
              "CLUSTER_NAME is required: the name of the cluster row to " <>
                "get-or-create (e.g. CLUSTER_NAME=nuremberg-01 bin/ensure-cluster)"

      name ->
        ensure_cluster_repos(name)

        :ok
    end
  end

  defp ensure_cluster_repos(name) do
    for repo <- repos() do
      {:ok, :ok, _started} =
        Ecto.Migrator.with_repo(repo, fn _repo -> ensure_cluster_row(name) end)
    end
  end

  # Reads all cluster rows, matching ResolveCluster's "exactly one"
  # lookup semantics, so this task can never leave the table in the
  # zero/many state that breaks every instance create.
  defp ensure_cluster_row(name) do
    case Ash.read(Cluster, authorize?: false) do
      {:ok, [%{name: ^name} = cluster]} ->
        exists =
          "cluster row #{name} exists (kubeconfig_ref: #{inspect(cluster.kubeconfig_ref)}) — left untouched"

        Logger.info(exists)

      {:ok, [%{name: existing}]} ->
        raise "cluster row #{inspect(existing)} already exists, not #{inspect(name)} — " <>
                "ResolveCluster needs exactly one row, so re-run with CLUSTER_NAME=#{existing} " <>
                "(or remove that row first); refusing to add a second"

      {:ok, []} ->
        Cluster.create!(%{name: name}, authorize?: false)

        created =
          "created cluster row #{name} (kubeconfig_ref: null — the in-cluster SA sentinel, ADR-0006 Am. 2)"

        Logger.info(created)

      {:ok, clusters} ->
        raise "#{length(clusters)} cluster rows already exist (need exactly one) — " <>
                "ResolveCluster is already broken; remove the extras in AshAdmin, then re-run"

      # defensive: cluster read DB failure (ExUnit can't kill the DB)
      # coveralls-ignore-start
      {:error, error} ->
        raise "cluster lookup failed: #{inspect(error)}"
        # coveralls-ignore-stop
    end

    :ok
  end

  @doc """
  Issues a one-time sign-in code for the platform owner (#165) through
  `OwnerSignIn` and prints it on the operator's terminal —
  the break-glass path while prod cannot deliver mail. The gate is
  `OWNER_EMAIL`, else the environment's single platform admin; nothing
  is seeded and no route exists.
  """
  @spec owner_signin_code :: :ok
  def owner_signin_code do
    load_app()

    # `eval` starts no supervision tree, so the AccessRules cache process
    # is absent (verified live: `GenServer.call` exits `:noproc`). TTL 0
    # reads the table straight through — the gate still runs, only the
    # 60s snapshot is skipped, which is what a one-shot operator task wants.
    Application.put_env(:flux_vale, :access_rules_cache_ttl_seconds, 0)

    for repo <- repos() do
      {:ok, :ok, _started} =
        Ecto.Migrator.with_repo(repo, fn _repo -> OwnerSignIn.issue_code() end)
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
