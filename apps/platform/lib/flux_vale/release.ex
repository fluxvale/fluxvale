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
  `bin/ensure-cluster`, `bin/label-instance-namespaces`, `bin/owner-signin`).

  `migrate/0` runs pending Ecto migrations per repo (advisory-locked by
  the migrator — the init container relies on this when pods race),
  `seed/0` runs the bring-up seed (platform admin + catalog, idempotent)
  and `ensure_cluster/0` get-or-creates this environment's Cluster row
  (#155); `label_instance_namespaces/0` claims this env's pre-#196
  instance namespaces for the env-scoped orphan sweep (#196).
  """

  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Ops.OwnerSignIn

  require Logger

  @app :flux_vale

  # #196: the same label key DeployInstance stamps and
  # SweepStrandedInstances scopes on — owned outright here like every
  # operation's constants.
  @env_label "fluxvale.io/platform-env"

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

  # Serialized on a transaction-scoped advisory lock keyed on the
  # clusters table: concurrent `ensure-cluster` runs (any `CLUSTER_NAME`)
  # take the lock before the read, so the empty-table case can't race two
  # inserts — the check-then-insert is atomic under the lock. Held until
  # the transaction commits, so the next holder reads the winner's row
  # (the wallet-debit discipline). Reads all rows, matching
  # `ResolveCluster`'s "exactly one" semantics, so the task can never
  # leave the table in the zero/many state that breaks instance creates.
  defp ensure_cluster_row(name) do
    {:ok, outcome} =
      FluxVale.Repo.transaction(fn ->
        FluxVale.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["clusters"])

        reconcile_cluster_row(name)
      end)

    outcome
  end

  defp reconcile_cluster_row(name) do
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
        {_cluster, _notifications} =
          Cluster
          |> Ash.Changeset.for_create(:create, %{name: name})
          # return_notifications? — taking the notification list here
          # keeps this transaction from warning about undelivered ones
          # (the PostEntry discipline). Cluster's create carries one
          # addressee-less notification, so the list is non-empty but
          # delivers nothing; `create!` keeps the typed error a bad name
          # raises.
          |> Ash.create!(authorize?: false, return_notifications?: true)

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
  Stamps this env's ownership label on every instance namespace this
  DB has a row for (`bin/label-instance-namespaces`, #196). The orphan
  sweep deletes only namespaces carrying its own `:platform_env`, and
  every namespace deployed before #196 is unlabeled — foreign by the
  sweep's rules — so each env claims its own once, after the fleet
  sets `PLATFORM_ENV`. The row is the authority (the namespace name
  embeds the instance uuid; each env's DB holds only rows it minted):
  a namespace no row answers for is never labeled here, and never any
  env's sweep to delete. Idempotent — the stamp is the same
  server-side-apply the deploy path runs, so a re-run is a no-op.

  A namespace that already 404s is skipped, not failed — that row is
  the sweeper's `:lost` lane (detection is the sweep's job, a one-shot
  labeling pass never flips rows). Rows mid-teardown (`:deleting`) are
  skipped too — their namespace is Terminating, and the sweep skips
  Terminating anyway. Any other failure (kubeconfig, API) raises after
  the pass, naming the count: the operator re-runs, and only the
  stragglers get stamped. Accepted race: a namespace deleted between
  the exists? check and the apply re-appears as an empty labeled shell
  (SSA creates it) — rare on a one-shot task, self-healing through the
  row's normal teardown, and the alternative (apply-without-check)
  would create shells for every not-yet-reconciled 404.
  """
  @spec label_instance_namespaces :: :ok
  def label_instance_namespaces do
    load_app()

    for repo <- repos() do
      {:ok, :ok, _started} =
        Ecto.Migrator.with_repo(repo, fn _repo -> label_namespaces() end)
    end

    :ok
  end

  defp label_namespaces do
    env = Application.fetch_env!(:flux_vale, :platform_env)

    # A nil namespace never deployed; :deleting is Terminating (skipped
    # above). Everything else with a row here is this env's to claim.
    candidates =
      Instance
      |> Ash.read!(authorize?: false)
      |> Enum.reject(fn instance ->
        is_nil(instance.namespace) or instance.status == :deleting
      end)

    failures =
      Enum.count(candidates, fn instance ->
        match?(:error, label_namespace(instance, env))
      end)

    if failures > 0 do
      raise "label-instance-namespaces: #{failures} namespace(s) failed to label — " <>
              "already-stamped ones are no-ops; re-run after fixing"
    end

    :ok
  end

  defp label_namespace(instance, env) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, true} <- Namespace.exists?(kubeconfig, instance.namespace),
         {:ok, _namespace} <-
           Namespace.create(kubeconfig, instance.namespace, %{labels: %{@env_label => env}}) do
      Logger.info("labeled #{instance.namespace} with #{@env_label}=#{env}")

      :ok
    else
      {:ok, false} ->
        Logger.warning(
          "#{instance.namespace} not found in cluster — left for the sweeper's :lost lane"
        )

        :skip

      {:error, reason} ->
        Logger.error("labeling #{instance.namespace} failed: #{inspect(reason)}")

        :error
    end
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
