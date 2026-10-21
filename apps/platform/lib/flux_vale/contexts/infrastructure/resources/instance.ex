defmodule FluxVale.Infrastructure.Instance do
  @moduledoc """
  An Instance — an instance *of* a catalog `AppVersion` — is FluxVale's
  unit of customer workload: an entire `fluxvale-app-<id>` namespace, not
  a Pod (ADR-0005). Created as a snapshot of the AppVersion's deploy
  blueprint; driven by a state machine
  (`pending → deploying → starting → running ⇄ stopped`; `error` from any
  state; `deleting`) through four AshOban triggers:

  - `:deploy` — one-shot; creates the namespace's K8s resources
    (Namespace, RoleBinding, ResourceQuota, NetworkPolicy, PVC, Secret,
    Deployment, Service, IngressRoute; a file-access instance adds the
    `file-access` Secret, `dav` Service, and `app-dav` IngressRoute,
    #190) and lands `:starting`
  - `:reconcile_status` — every minute; mirrors Deployment readiness
    into `status` — the only writer of `:running` — demotes on failed
    rollouts, times out stuck deploys
  - `:settle_usage` — every 15 min; accrues the flat rate over elapsed
    time against the org wallet (#121, ADR-0005 Am. 1 / ADR-0028) —
    see `Instance.PerformSettle`
  - `:teardown` — one-shot; deletes the K8s resources, hard-deletes the
    row on success, retries transient failures

  Metering anchors (`running_since`/`running_until`,
  `storage_metering_since`) are maintained by transitions and consumed
  by settlement; the pricing snapshot (`size`, `grandfathered_*`)
  prices the accrual — creation-time cents for the first year, then
  the live Size row (or, for a sizeless custom allocation, the live
  anchor formula from its own allocation — #186) after (settled on
  #121).

  Allocation (`cpu_cores`/`memory_mb`/`storage_gb`) is user-choosable
  at create (#180): the AppVersion's defaults are the advisory
  recommendation (DeriveFromAppVersion applies them when the creator
  sends none), the attribute constraints are the hard floors, and the
  below-recommendation acknowledgment is a wizard concern — the
  resource floors below the recommendation, it doesn't gate on it.

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
  alias FluxVale.Infrastructure.Instance.PerformSettle
  alias FluxVale.Infrastructure.Instance.PerformTeardown
  alias FluxVale.Infrastructure.Instance.ResolveCluster
  alias FluxVale.Infrastructure.Instance.SetOrganizationFromActor
  alias FluxVale.Infrastructure.Instance.StatusTransition
  alias FluxVale.Infrastructure.Instance.ValidateEnvVars
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.StartInstance
  alias FluxVale.Infrastructure.Operations.StopInstance

  postgres do
    table("instances")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
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
        where(expr(status in [:deploying, :starting, :running]))
        worker_module_name(__MODULE__.Reconcile.Worker)
        scheduler_module_name(__MODULE__.Reconcile.Scheduler)
      end

      # ADR-0005's fourth trigger (decided on #73, shipped with #121):
      # flat-rate accrual against the org wallet — see PerformSettle.
      trigger :settle_usage do
        action(:perform_settle)
        queue(:settler)
        scheduler_cron("*/15 * * * *")
        where(expr(not is_nil(storage_metering_since)))
        worker_module_name(__MODULE__.Settle.Worker)
        scheduler_module_name(__MODULE__.Settle.Scheduler)
      end

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
      description("AshOban trigger interactions bypass actor policies")
      authorize_if(always())
    end

    policy action_type(:read) do
      description("Members read their org's instances")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action_type(:create) do
      description(
        "#124's deploy gate: any signed-in actor with a funded org wallet creates instances (org resolved from actor) — policy-land, so the API can't bypass it"
      )

      forbid_unless(actor_present())
      authorize_if(FluxVale.Checks.ActorOrgWalletFunded)
    end

    # The member-reachable updates, named per-action: a broad
    # action_type(:update) policy beside the gated ones would OR the
    # gate away (policies are OR'd) — and deploy/start spend too
    # (#124: "new instance deploys blocked at balance ≤ 0" covers the
    # pending/error retry path, not just fresh creates).
    policy action(:deploy) do
      description("Deploy/retry needs membership AND a funded wallet (#124)")
      forbid_unless(relates_to_actor_via([:organization, :members]))
      authorize_if(FluxVale.Checks.ActorOrgWalletFunded)
    end

    policy action(:settle_anchors) do
      description("System-only: settlement cursor writes (authorize?: false)")
      forbid_if(always())
    end

    policy action(:stop) do
      description("Members stop their org's instances")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action(:start) do
      description("Resume needs membership AND a funded wallet (#124)")
      forbid_unless(relates_to_actor_via([:organization, :members]))
      authorize_if(FluxVale.Checks.ActorOrgWalletFunded)
    end

    policy action_type(:destroy) do
      description("Members destroy their org's instances")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action(:delete) do
      description("Ownership is enforced by the authorized get_by_id read inside the action")
      authorize_if(actor_present())
    end
  end

  pub_sub do
    # Phoenix.PubSub's registered-name style: module Phoenix.PubSub +
    # name FluxVale.PubSub calls Phoenix.PubSub.broadcast/3 with the
    # app's pubsub as the first arg (application.ex's child).
    module(Phoenix.PubSub)
    name(FluxVale.PubSub)

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

    # Where the deployer mounts the data PVC (#189) — snapshotted from
    # the AppVersion's blueprint (DeriveFromAppVersion) like image/port.
    # Defaults to "/data" so rows created before this column existed
    # (and any path the derive doesn't set) keep mounting where the old
    # hard-coded deployer mounted them.
    attribute :storage_mount_path, :string do
      allow_nil?(false)
      default("/data")
      public?(true)
    end

    # File access snapshot (#190, ADR-0035): copied from the App's
    # catalog-declared `file_access` at create (DeriveFromAppVersion) —
    # the deploy op reads it to decide the WebDAV sidecar. Snapshot
    # stance like image/port: a later catalog edit never re-specs a
    # running Instance; the sidecar lands on the next deploy instead.
    attribute :file_access, :boolean do
      allow_nil?(false)
      default(false)
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

    # #179: the closed failure classification the user-facing copy maps
    # through. Technical detail stays in status_message (admin-only
    # reveal); non-admins get copy derived from this atom. nil on
    # non-error rows — set only by :error writes, cleared on recovery.
    attribute :failure_reason, FluxVale.Infrastructure.Types.InstanceFailureReason do
      public?(false)
    end

    # Staleness signal for the reconcile timeout — set when a deploy is
    # enqueued, not on every write (updated_at bumps on no-op reconciles).
    attribute :deployed_at, :utc_datetime_usec do
      public?(true)
    end

    # Metering anchors (ADR-0005 Am. 1 / ADR-0008 §2): running_since
    # opens the current running interval (nil whenever not running);
    # unbilled_running_usec carries running time closed by a stop but
    # not yet settled — integer microseconds of TIME, so stop/start
    # churn inside one tick can never drop an interval. Storage
    # metering spans stop/start (the PVC persists) and doubles as the
    # settlement cursor. Internal — only transitions and settlement
    # write them.
    attribute :running_since, :utc_datetime_usec do
      public?(false)
    end

    attribute :unbilled_running_usec, :integer do
      public?(false)
      allow_nil?(false)
      default(0)
      constraints(min: 0)
    end

    attribute :storage_metering_since, :utc_datetime_usec do
      public?(false)
    end

    # Pricing snapshot (#121/#186): creation-time cents price the
    # accrual until grandfathered_until lapses (created_at + 1 year),
    # then settlement reads the live Size row by size_id — or the live
    # anchor formula from this instance's allocation for a custom
    # (sizeless) snapshot. Snapshot lands at create
    # (DeriveFromAppVersion) — price and clock from one moment. Null
    # with no size on pre-#121 rows whose version lost its size: an
    # unpriced instance accrues nothing (settle no-ops, loudly
    # logged).
    attribute :grandfathered_until, :utc_datetime_usec do
      public?(false)
    end

    attribute :grandfathered_monthly_cents, :integer do
      public?(false)
      constraints(min: 0)
    end

    attribute :grandfathered_stopped_monthly_cents, :integer do
      public?(false)
      constraints(min: 0)
    end

    # Allocation is user-choosable at create (#180): the AppVersion's
    # defaults are the advisory recommendation, not a ceiling or floor.
    # Derived-field pattern (see image/port): allow_nil? + presence
    # below — DeriveFromAppVersion fills them from the creator's choice
    # or the version's defaults, so no static default here to collide
    # with the derive. The constraints are the hard platform floors —
    # the same legal-allocation bounds Size holds (its own attribute
    # notes), so a below-recommendation pick can go as low as a
    # size-shaped allocation and no lower.
    attribute :cpu_cores, :decimal do
      public?(true)
      # Same numeric-encode safety stance as the maxima below: a
      # finite-but-huge Decimal (1e400000) passes greater_than: 0 and
      # then crashes the Postgrex write.
      constraints(greater_than: 0, max: 64)
    end

    # The maxima are bigint-encode safety (Postgrex raises past
    # 2^63-1 — a plainly-typed big number must fail validation, not
    # crash the writer) with headroom over any current box; not
    # capacity promises. Revisit when bigger boxes exist.
    attribute :memory_mb, :integer do
      public?(true)
      constraints(min: 1, max: 65_536)
    end

    attribute :storage_gb, :integer do
      public?(true)
      # 0 stays legal — config-only apps (Size's own stance).
      constraints(min: 0, max: 10_240)
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
    belongs_to :organization, FluxVale.Accounts.Organization do
      # allow_nil? true + presence validation: SetOrganizationFromActor
      # resolves it from the actor's membership before validations run
      # (derived-field pattern). The org is the single ownership axis
      # (#119) — instances have no user FK.
      public?(true)
    end

    belongs_to :cluster, FluxVale.Infrastructure.Cluster do
      # Same derived-field pattern as :organization (ResolveCluster pins it).
      public?(true)
    end

    belongs_to :app_version, FluxVale.Catalog.AppVersion do
      allow_nil?(false)
      public?(true)
    end

    # The priced unit snapshot (#121): the version's recommended_size at
    # create. Allocation already snapshots; the size rides along so a
    # later version re-point can't reprice a running instance's live
    # reads after the grace lapses.
    belongs_to :size, FluxVale.Pricing.Size do
      public?(false)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name, :cpu_cores, :memory_mb, :storage_gb, :env_vars, :app_version_id])

      change(SetOrganizationFromActor)
      change(ResolveCluster)
      change(DeriveFromAppVersion)
      change(GenerateSlug)
    end

    read :get_by_id do
      description("Get an instance by id")
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :list_for_actor do
      description(
        "The actor's own instances (#74's list surface; sorted newest-first at the query) — org-scoped since #119: instances belong to the actor's org"
      )

      filter(expr(exists(organization.memberships, user_id == ^actor(:id))))
    end

    # #124's burn-rate input: every instance of an org, priced. System
    # seam (the sweep runs authorize?: false); members have no call for
    # an org-wide unpaginated list — list_for_actor is theirs.
    read :list_for_organization do
      description("The org's instances (#124's runway/burn-rate input)")
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end

    update :update_status do
      description(
        "System status write — the state machine's single funnel (MaintainAnchors + StatusTransition)."
      )

      # namespace deliberately NOT accepted: it is write-once (the deploy
      # action pins fluxvale-app-<id>), and an owner-reachable write here
      # could point teardown at any namespace on the cluster. failure_reason
      # rides the same system-only posture (#179): set on :error writes,
      # nil on every other — InstanceK8s.update_status enforces the
      # pairing.
      accept([:status, :status_message, :failure_reason])
      require_atomic?(false)

      change(MaintainAnchors)

      validate(StatusTransition)
    end

    update :deploy do
      description(
        "Enqueues the background deploy job; lands :deploying with the namespace pinned."
      )

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
          |> Ash.Changeset.force_change_attribute(:failure_reason, nil)
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
      description("Scales the Deployment to 0 — the product's pause (storage keeps accruing).")
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
      description(
        "Scales the Deployment back to 1 — lands :starting; the reconciler confirms readiness."
      )

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
      description("""
      Deletes an instance (async teardown). Deployed instances flip to
      :deleting and enqueue the AshOban :teardown trigger, which tears
      down K8s resources and hard-deletes the row on success (retries
      transient failures; on_error surfaces exhaustion as :error with a
      retry hint). Never-deployed rows (no namespace) hard-delete
      synchronously. Ownership is enforced by the authorized get_by_id
      read below (v1's fluxvale-h0l shape).
      """)

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
      description("The :deploy trigger's body — see Operations.DeployInstance.")
      require_atomic?(false)
      accept([])

      change(PerformDeploy)
    end

    update :perform_reconcile do
      description("The :reconcile_status trigger's body — see Operations.ReconcileInstance.")
      require_atomic?(false)
      accept([])

      change(PerformReconcile)
    end

    update :perform_settle do
      description("The :settle_usage trigger's body — see Instance.PerformSettle (#121).")
      require_atomic?(false)
      accept([])

      change(PerformSettle)
    end

    update :settle_anchors do
      description(
        "System-only: settlement's cursor writes (PerformSettle, under the wallet lock)."
      )

      accept([:storage_metering_since, :unbilled_running_usec])
      require_atomic?(false)
    end

    update :perform_teardown do
      description("""
      The :teardown trigger's body — tears down K8s resources and
      hard-deletes the row on success; returns an error on K8s failure
      so Oban retries (see Operations.TeardownInstance).
      """)

      require_atomic?(false)
      accept([])

      change(PerformTeardown)
    end

    update :mark_deploy_error do
      description("Error handler for the :deploy trigger — unexpected job failures land :error.")
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
        |> Ash.Changeset.force_change_attribute(:failure_reason, :deploy_failed)
      end)
    end

    update :mark_teardown_error do
      description("""
      Error handler for the :teardown trigger — flips to :error once
      retries are exhausted so the failed delete is visible and retryable.
      Keeps the namespace so a retry can find the K8s resources.
      """)

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
        |> Ash.Changeset.force_change_attribute(:failure_reason, :teardown_failed)
      end)
    end

    destroy :destroy do
      primary?(true)
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:create)
    define(:update_status)
    define(:destroy)
    define(:get_by_id, args: [:id])
    define(:list_for_actor)
    define(:list_for_organization, args: [:organization_id])
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

      InstanceK8s.update_status(
        deleting,
        :error,
        "Delete failed to enqueue; retry delete",
        :teardown_failed
      )

      # coveralls-ignore-stop
  end

  validations do
    # Derived fields (allow_nil? true above) get explicit presence here —
    # validations run after changes (v1 pattern, see attributes notes).
    validate(present(:organization_id), on: :create, message: "is required")

    validate(present(:cluster_id), on: :create, message: "is required")

    validate(present(:image), on: :create, message: "is required")

    validate(present(:port), on: :create, message: "is required")

    validate(present(:healthcheck_path), on: :create, message: "is required")

    validate(present(:cpu_cores), on: :create, message: "is required")

    validate(present(:memory_mb), on: :create, message: "is required")

    validate(present(:storage_gb), on: :create, message: "is required")

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
