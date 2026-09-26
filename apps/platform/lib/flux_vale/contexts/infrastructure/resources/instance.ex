defmodule FluxVale.Infrastructure.Instance do
  @moduledoc """
  An Instance — an instance *of* a catalog `AppVersion` — is FluxVale's
  unit of customer workload: an entire `fluxvale-app-<id>` namespace, not
  a Pod (ADR-0005). Created as a snapshot of the AppVersion's deploy
  blueprint; driven by a state machine
  (`pending → deploying → starting → running ⇄ stopped`; `error` from any
  state; `deleting`) through three AshOban triggers:

  - `:deploy` — one-shot; creates the namespace's K8s resources
    (Namespace, RoleBinding, ResourceQuota, NetworkPolicy, PVC, Secret,
    Deployment, Service, IngressRoute) and lands `:starting`
  - `:reconcile_status` — every minute; mirrors Deployment readiness
    into `status` — the only writer of `:running` — demotes on failed
    rollouts, times out stuck deploys
  - `:teardown` — one-shot; deletes the K8s resources, hard-deletes the
    row on success, retries transient failures

  ADR-0005's fourth trigger (`settle_usage`) is deferred to M5 with the
  Wallet/ledger it posts to (decided on #73); its metering anchors —
  `running_since`, `storage_metering_since` — ship now, maintained by
  transitions, so M5 is additive.

  `slug` doubles as the DNS subdomain (`<slug>.<instances_base_domain>`)
  and is haikunate-generated per cluster (v1 port). `stop`/`start` are
  synchronous scale-to-zero/one; `delete` is the async teardown entry.

  Every status-writing action broadcasts the record on `instances:<id>`
  (Ash.Notifier.PubSub, #74): the LiveView status surface subscribes
  instead of polling (ADR-0002's named wrong bet; correct unclustered
  at one replica, ADR-0016 row 1).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias FluxVale.Infrastructure.Instance.DeriveFromAppVersion
  alias FluxVale.Infrastructure.Instance.GenerateSlug
  alias FluxVale.Infrastructure.Instance.MaintainAnchors
  alias FluxVale.Infrastructure.Instance.PerformDeploy
  alias FluxVale.Infrastructure.Instance.PerformReconcile
  alias FluxVale.Infrastructure.Instance.PerformTeardown
  alias FluxVale.Infrastructure.Instance.ResolveCluster
  alias FluxVale.Infrastructure.Instance.SetUserFromActor
  alias FluxVale.Infrastructure.Instance.StatusTransition
  alias FluxVale.Infrastructure.Instance.ValidateEnvVars
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.StartInstance
  alias FluxVale.Infrastructure.Operations.StopInstance

  postgres do
    table "instances"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  oban do
    triggers do
      trigger :deploy do
        action(:perform_deploy)
        queue(:deployments)
        scheduler_cron(false)
        on_error(:mark_deploy_error)
        worker_module_name(__MODULE__.Deploy.Worker)
        scheduler_module_name(__MODULE__.Deploy.Scheduler)
      end

      trigger :reconcile_status do
        action(:perform_reconcile)
        queue(:reconciler)
        scheduler_cron("* * * * *")
        where expr(status in [:deploying, :starting, :running])
        worker_module_name(__MODULE__.Reconcile.Worker)
        scheduler_module_name(__MODULE__.Reconcile.Scheduler)
      end

      # ADR-0005's fourth trigger, settle_usage, is M5 scope (decided on
      # #73): the Wallet/ledger it posts to doesn't exist yet. The anchors
      # it will advance ship in this resource's schema now.

      trigger :teardown do
        action(:perform_teardown)
        queue(:deployments)
        scheduler_cron(false)
        on_error(:mark_teardown_error)
        worker_module_name(__MODULE__.Teardown.Worker)
        scheduler_module_name(__MODULE__.Teardown.Scheduler)
      end
    end
  end

  policies do
    # Trigger-fired actions run actorless in the Oban context (v1 stance,
    # fluxvale-ozu): the user-facing entry actions carry the checks.
    bypass AshOban.Checks.AshObanInteraction do
      description "AshOban trigger interactions bypass actor policies"
      authorize_if(always())
    end

    policy action_type(:read) do
      description "Owners read their instances"
      authorize_if(relates_to_actor_via(:user))
    end

    policy action_type(:create) do
      description "Any signed-in actor creates instances (owner set from actor)"
      authorize_if(actor_present())
    end

    policy action_type(:update) do
      description "Owners drive lifecycle transitions"
      authorize_if(relates_to_actor_via(:user))
    end

    policy action_type(:destroy) do
      description "Owners destroy instances"
      authorize_if(relates_to_actor_via(:user))
    end

    policy action(:delete) do
      description "Ownership is enforced by the authorized get_by_id read inside the action"
      authorize_if(actor_present())
    end
  end

  pub_sub do
    # Phoenix.PubSub's registered-name style: module Phoenix.PubSub +
    # name FluxVale.PubSub calls Phoenix.PubSub.broadcast/3 with the
    # app's pubsub as the first arg (application.ex's child).
    module(Phoenix.PubSub)
    name FluxVale.PubSub

    # #74: every state-machine writer lands on instances:<id>.
    # :update_status is the system funnel — the deploy/reconcile/teardown
    # workers and stop/start/delete all write through it. :deploy and the
    # two error handlers write status outside the funnel; :destroy covers
    # teardown's hard delete, the one status change that never passes
    # through it (a :deleting instance's page needs the event to leave).
    # The funnel's and :deploy's publishes are pinned in
    # instance_pub_sub_test; the error handlers' publishes ride the same
    # DSL (their actions run in #73's on_error tests — under inline
    # testing a trigger crash escapes to the caller, so they can't be
    # observed there).
    publish(:update_status, ["instances", :id])
    publish(:deploy, ["instances", :id])
    publish(:mark_deploy_error, ["instances", :id])
    publish(:mark_teardown_error, ["instances", :id])
    publish(:destroy, ["instances", :id])
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    # Haikunate-generated (GenerateSlug); doubles as the DNS subdomain.
    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
    end

    # fluxvale-app-<id>, set on deploy (nil = never deployed) — the
    # ADR-0005 namespace convention.
    attribute :namespace, :string do
      public?(true)
    end

    # Blueprint snapshot from the AppVersion (DeriveFromAppVersion) —
    # allow_nil? true + explicit presence validations: derived fields
    # must not trip auto-validations before changes run (v1 pattern).
    attribute :image, :string do
      public?(true)
    end

    attribute :port, :integer do
      public?(true)
    end

    attribute :healthcheck_path, :string do
      public?(true)
    end

    attribute :status, FluxVale.Infrastructure.Types.InstanceStatus do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    attribute :status_message, :string do
      public?(true)
    end

    # Staleness signal for the reconcile timeout — set when a deploy is
    # enqueued, not on every write (updated_at bumps on no-op reconciles).
    attribute :deployed_at, :utc_datetime_usec do
      public?(true)
    end

    # Metering anchors (ADR-0005 Am. 1 / ADR-0008 §2): running_since
    # spans the current running interval; storage_metering_since spans
    # storage billing across stop/start (the PVC persists). Internal —
    # M5's settle_usage advances them against the ledger.
    attribute :running_since, :utc_datetime_usec do
      public?(false)
    end

    attribute :storage_metering_since, :utc_datetime_usec do
      public?(false)
    end

    attribute :cpu_cores, :decimal do
      allow_nil?(false)
      default(Decimal.new("0.5"))
      public?(true)
    end

    attribute :memory_mb, :integer do
      allow_nil?(false)
      default(256)
      public?(true)
    end

    attribute :storage_gb, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    # Merged env (catalog defaults under user values), string values —
    # the k8s Secret's exact contents.
    attribute :env_vars, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, FluxVale.Identity.User do
      # allow_nil? true + presence validation: SetUserFromActor populates
      # it from the actor before validations run (v1 pattern).
      public?(true)
    end

    belongs_to :cluster, FluxVale.Infrastructure.Cluster do
      # Same derived-field pattern as :user (ResolveCluster pins it).
      public?(true)
    end

    belongs_to :app_version, FluxVale.Catalog.AppVersion do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name, :env_vars, :app_version_id])

      change(SetUserFromActor)
      change(ResolveCluster)
      change(DeriveFromAppVersion)
      change(GenerateSlug)
    end

    read :get_by_id do
      description "Get an instance by id"
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :list_for_actor do
      description "The actor's own instances (#74's list surface; sorted newest-first at the query)"
      filter(expr(user_id == ^actor(:id)))
    end

    update :update_status do
      description "System status write — the state machine's single funnel (MaintainAnchors + StatusTransition)."
      # namespace deliberately NOT accepted: it is write-once (the deploy
      # action pins fluxvale-app-<id>), and an owner-reachable write here
      # could point teardown at any namespace on the cluster.
      accept([:status, :status_message])
      require_atomic?(false)

      change(MaintainAnchors)

      validate(StatusTransition)
    end

    update :deploy do
      description "Enqueues the background deploy job; lands :deploying with the namespace pinned."
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        instance = changeset.data

        if instance.status in [:pending, :error] do
          namespace = "fluxvale-app-#{instance.id}"

          changeset
          |> Ash.Changeset.force_change_attribute(:status, :deploying)
          |> Ash.Changeset.force_change_attribute(:namespace, namespace)
          |> Ash.Changeset.force_change_attribute(:status_message, "Deploying to Kubernetes...")
          |> Ash.Changeset.force_change_attribute(:deployed_at, DateTime.utc_now())
        else
          Ash.Changeset.add_error(
            changeset,
            "cannot deploy instance in #{instance.status} state (must be pending or error)"
          )
        end
      end)

      change({AshOban.Changes.RunObanTrigger, trigger: :deploy})
    end

    update :stop do
      description "Scales the Deployment to 0 — the product's pause (storage keeps accruing)."
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        instance = changeset.data

        if instance.status == :running do
          Ash.Changeset.after_action(changeset, fn _changeset, instance ->
            StopInstance.call(instance)
          end)
        else
          Ash.Changeset.add_error(
            changeset,
            "cannot stop instance in #{instance.status} state (must be running)"
          )
        end
      end)
    end

    update :start do
      description "Scales the Deployment back to 1 — lands :starting; the reconciler confirms readiness."
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        instance = changeset.data

        if instance.status == :stopped do
          Ash.Changeset.after_action(changeset, fn _changeset, instance ->
            StartInstance.call(instance)
          end)
        else
          Ash.Changeset.add_error(
            changeset,
            "cannot start instance in #{instance.status} state (must be stopped)"
          )
        end
      end)
    end

    action :delete, :struct do
      description """
      Deletes an instance (async teardown). Deployed instances flip to
      :deleting and enqueue the AshOban :teardown trigger, which tears
      down K8s resources and hard-deletes the row on success (retries
      transient failures; on_error surfaces exhaustion as :error with a
      retry hint). Never-deployed rows (no namespace) hard-delete
      synchronously. Ownership is enforced by the authorized get_by_id
      read below (v1's fluxvale-h0l shape).
      """

      argument(:id, :uuid, allow_nil?: false, public?: true)
      constraints(instance_of: __MODULE__)

      run(fn input, %{actor: actor, authorize?: authorize?} ->
        case get_by_id(input.arguments.id, actor: actor, authorize?: authorize?) do
          {:ok, instance} ->
            cond do
              instance.status == :deleting ->
                # Already mid-teardown — don't enqueue a duplicate job.
                {:ok, instance}

              instance.namespace ->
                with {:ok, deleting} <-
                       InstanceK8s.update_status(
                         instance,
                         :deleting,
                         "Tearing down K8s resources..."
                       ) do
                  enqueue_teardown!(deleting)
                end

              true ->
                # Never deployed — hard-delete synchronously.
                case Ash.destroy(instance, actor: actor, authorize?: authorize?) do
                  :ok -> {:ok, instance}
                  # coveralls-ignore-next-line - defensive: no FK dependents.
                  {:error, _reason} = error -> error
                end
            end

          {:error, _reason} = error ->
            error
        end
      end)
    end

    update :perform_deploy do
      description "The :deploy trigger's body — see Operations.DeployInstance."
      require_atomic?(false)
      accept([])

      change(PerformDeploy)
    end

    update :perform_reconcile do
      description "The :reconcile_status trigger's body — see Operations.ReconcileInstance."
      require_atomic?(false)
      accept([])

      change(PerformReconcile)
    end

    update :perform_teardown do
      description """
      The :teardown trigger's body — tears down K8s resources and
      hard-deletes the row on success; returns an error on K8s failure
      so Oban retries (see Operations.TeardownInstance).
      """

      require_atomic?(false)
      accept([])

      change(PerformTeardown)
    end

    update :mark_deploy_error do
      description "Error handler for the :deploy trigger — unexpected job failures land :error."
      require_atomic?(false)
      accept([])
      argument(:error, :map, allow_nil?: true)

      change(fn changeset, _context ->
        # The :error argument carries the Ash error class, but the normal
        # K8s path already wrote a detailed message — this handler only
        # fires on crashes that bypassed it.
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :error)
        |> Ash.Changeset.force_change_attribute(:status_message, "Deploy job failed unexpectedly")
      end)
    end

    update :mark_teardown_error do
      description """
      Error handler for the :teardown trigger — flips to :error once
      retries are exhausted so the failed delete is visible and retryable.
      Keeps the namespace so a retry can find the K8s resources.
      """

      require_atomic?(false)
      accept([])
      argument(:error, :map, allow_nil?: true)

      change(fn changeset, _context ->
        # Per-attempt reasons live in the Oban job's errors array (Oban
        # dashboards); the row needs only the retry hint.
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :error)
        |> Ash.Changeset.force_change_attribute(
          :status_message,
          "Instance teardown failed; retry delete to attempt again"
        )
      end)
    end

    destroy :destroy do
      primary?(true)
    end
  end

  code_interface do
    domain FluxVale.Infrastructure

    define(:create)
    define(:update_status)
    define(:destroy)
    define(:get_by_id, args: [:id])
    define(:list_for_actor)
    define(:delete, args: [:id])
    define(:deploy)
    define(:stop)
    define(:start)
  end

  identities do
    identity(:unique_slug_per_cluster, [:slug, :cluster_id])
  end

  # The status write commits before the job insert (separate writes), so
  # a raising insert would strand the row in :deleting with no job — and
  # the :deleting guard above would block every retry. Revert to :error
  # (allowed from any state) and fail the action instead: the user's
  # retry re-enters cleanly.
  defp enqueue_teardown!(deleting) do
    AshOban.run_trigger(deleting, :teardown)
    {:ok, deleting}
  rescue
    # coveralls-ignore-start - defensive: Oban.insert! raises only on a
    # DB failure between the two writes; ExUnit cannot kill the DB.
    exception ->
      require Logger

      Logger.error(
        "Instance #{deleting.id} teardown enqueue failed: #{Exception.message(exception)}"
      )

      InstanceK8s.update_status(deleting, :error, "Delete failed to enqueue; retry delete")

      # coveralls-ignore-stop
  end

  validations do
    # Derived fields (allow_nil? true above) get explicit presence here —
    # validations run after changes (v1 pattern, see attributes notes).
    validate(present(:user_id), on: :create, message: "is required")

    validate(present(:cluster_id), on: :create, message: "is required")

    validate(present(:image), on: :create, message: "is required")

    validate(present(:port), on: :create, message: "is required")

    validate(present(:healthcheck_path), on: :create, message: "is required")

    validate(
      match(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/),
      on: :create,
      message: "must contain only lowercase alphanumeric characters and hyphens"
    )

    validate(string_length(:status_message, max: 500), where: [present(:status_message)])

    validate({ValidateEnvVars, []}, on: :create)

    validate(
      compare(:port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535),
      on: :create,
      message: "must be a valid port number (1-65535)"
    )
  end
end
