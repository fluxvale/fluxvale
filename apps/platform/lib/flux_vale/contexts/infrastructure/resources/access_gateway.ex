defmodule FluxVale.Infrastructure.AccessGateway do
  @moduledoc """
  A private-access gateway — one per organization (ADR-0039): the
  always-on pod that puts the org's `private` instances on the owner's
  own tailnet. Topology B, and the provider boundary's subject.

  The row is **configuration and state**, never a credential:
  `credential_secret_ref` names a Secret in the access namespace and
  nothing else; the auth key itself never reaches Postgres (the
  `backup-config` pattern, ADR-0037 §4).

  `hostname` is the opaque `fv-<short-uuid>` (ADR-0039 §1) — serve and
  Let's Encrypt put a node's machine name in the public CT ledger, so
  neither the app type nor the org name may appear. It is generated at
  create and never derived from anything user-visible.

  Billing is existence-based (ADR-0039 §5): `PerformSettle` prorates the
  monthly rate over `metering_since` → now, exactly the instance
  discipline (wallet advisory lock, `FOR UPDATE` re-read, keyless debit,
  anchor advance). Only `:active` accrues — a `:suspended` gateway is
  scaled to zero and bills nothing, and a `:needs_attention` one is not
  giving the owner reachability, so charging would be dishonest. That
  makes `:active` the single accrual arm, and the state machine the
  billing switch.

  Instances attach through `Operations.AttachInstance` /
  `DetachInstance`, which own the cluster side (serve config + the
  namespace NetworkPolicy's access-namespace entry). The `access_routes`
  rows are the pairing record: they are what the wake endpoint
  authorizes against (ADR-0039 §6), so an attach is also the owner's
  consent that the gateway may start the instance.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias FluxVale.Infrastructure.AccessGateway.GenerateHostname
  alias FluxVale.Infrastructure.AccessGateway.PerformSettle
  alias FluxVale.Infrastructure.AccessGateway.PerformTeardown
  alias FluxVale.Infrastructure.AccessGateway.ProvisionCluster
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance

  require Ash.Query

  postgres do
    table("access_gateways")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # Restrict, not cascade. A DB-level cascade would be a silent lie: it
    # drops the row while the Deployment, its two Secrets and the PVC keep
    # running in the access namespace, still joined to the customer's
    # tailnet under their auth key — with no row left for any sweep to
    # find. Refusing the org delete forces the caller through the
    # teardown path (opt-out, or the ladder's destroy arm), which removes
    # the cluster objects and needs the row to exist while it does.
    #
    # Accepted for v1: org deletion is not a supported flow yet (no action
    # does it); when it lands it must tear gateways down first, exactly as
    # it must for instances.
    references do
      reference(:organization, on_delete: :restrict)
    end
  end

  oban do
    triggers do
      # Re-converge the cluster objects — NOT the create path. `create`
      # is synchronous (it holds the auth key, which must never reach
      # Postgres) and rolls back on failure, so there is no row to retry:
      # a failed create is the owner's retry. This trigger is invoked
      # explicitly (`AshOban.run_trigger/2`) when the objects drifted
      # after a successful create — a deleted Deployment, a cluster
      # outage — and it re-reads the key from the Secret. Idempotent by
      # SSA on per-gateway names.
      trigger :provision do
        action(:perform_provision)
        queue(:deployments)
        scheduler_cron(false)
        on_error(:mark_provision_error)
        worker_module_name(__MODULE__.Provision.Worker)
        scheduler_module_name(__MODULE__.Provision.Scheduler)
      end

      # ADR-0039 §2's observed-state rule: the only promoter to :active.
      # Every minute, like the instance reconciler — a gateway that is
      # not observed can neither bill nor show "Connected".
      trigger :observe do
        action(:perform_observe)
        # Its own queue: see the `gateway_observe` note in config.exs —
        # the instance reconciler is the only writer of `:running` and
        # runs at concurrency 1, so it must not queue behind gateway reads.
        queue(:gateway_observe)
        scheduler_cron("* * * * *")
        where(expr(state in [:provisioning, :active, :needs_attention]))
        worker_module_name(__MODULE__.Observe.Worker)
        scheduler_module_name(__MODULE__.Observe.Scheduler)
      end

      # ADR-0039 §5: existence accrual on the instance cadence.
      trigger :settle_usage do
        action(:perform_settle)
        queue(:settler)
        scheduler_cron("*/15 * * * *")
        where(expr(state in [:active, :needs_attention]))
        worker_module_name(__MODULE__.Settle.Worker)
        scheduler_module_name(__MODULE__.Settle.Scheduler)
      end

      # Opt-out: delete the cluster objects, then the row.
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
    # Trigger-fired actions run actorless in the Oban context (the
    # Instance stance): the user-facing entry actions carry the checks.
    bypass AshOban.Checks.AshObanInteraction do
      description("AshOban trigger interactions bypass actor policies")
      authorize_if(always())
    end

    policy action_type(:read) do
      description("Members read their org's gateway (the panel's status surface)")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # Opting in is a paid add-on: the same funded gate instance creates
    # carry (#124), because the first accrual lands within one tick.
    policy action(:create) do
      description("Members opt their org in — membership AND a funded wallet, the #124 gate")

      forbid_unless(actor_present())
      authorize_if(FluxVale.Checks.ActorOrgWalletFunded)
    end

    policy action(:update_credential) do
      description("Members re-paste the auth key (the NeedsLogin recovery) — no charge, no spend")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action(:resume) do
      description("Resuming after suspension spends money — membership AND a funded wallet")
      forbid_unless(relates_to_actor_via([:organization, :members]))
      authorize_if(FluxVale.Checks.ActorOrgWalletFunded)
    end

    policy action(:suspend) do
      description("System-only: the zero-balance ladder's suspension (authorize?: false)")
      forbid_if(always())
    end

    # The observed-status write is the platform's read of the cluster,
    # never the owner's opinion of it.
    policy action(:update_state) do
      description("System-only: observed gateway state (authorize?: false)")
      forbid_if(always())
    end

    # The claims/token-ref writes are the claiming system's (the
    # claim/unclaim operations and RemoveAccessDomain's unclaim limb run
    # them authorize?: false — the ops seam).
    policy action([:set_api_token_ref, :update_claims]) do
      description("System-only: the API-token ref and tailnet-claims writes (authorize?: false)")
      forbid_if(always())
    end

    policy action_type(:destroy) do
      description("Members tear their org's gateway down (opt-out)")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action(:delete) do
      description("Ownership is enforced by the authorized get_by_id read inside the action")
      authorize_if(actor_present())
    end

    policy action(:destroy_after_teardown) do
      description("System-only: the teardown trigger's hard delete (authorize?: false)")
      forbid_if(always())
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(FluxVale.PubSub)

    # The panel's live status surface (#74's stance, same table): every
    # state writer lands here, so the badge moves without polling.
    publish(:update_state, ["access_gateways", :organization_id])
    publish(:create, ["access_gateways", :organization_id])
    # The owner/state-machine arms that bypass the :update_state funnel
    # (force-changes on their own actions) — without these an open panel
    # never sees the ladder's suspension, a resume or a re-paste from
    # another tab, or an error handler's landing.
    publish(:suspend, ["access_gateways", :organization_id])
    publish(:resume, ["access_gateways", :organization_id])
    publish(:update_credential, ["access_gateways", :organization_id])
    publish(:mark_provision_error, ["access_gateways", :organization_id])
    publish(:mark_teardown_error, ["access_gateways", :organization_id])
    # The teardown's hard delete is the one state change that never
    # passes through :update_state — a subscribed panel needs the event
    # to leave the page (the Instance notifier's stance).
    publish(:destroy_after_teardown, ["access_gateways", :organization_id])
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :hostname, :string do
      allow_nil?(false)
      public?(true)
      # fv-<8 hex> — the opaque name (ADR-0039 §1). Lowercase DNS label.
      constraints(match: ~r/\Afv-[0-9a-f]{8}\z/)
    end

    # The tailnet's MagicDNS suffix (`<tailnet>.ts.net`) — the other
    # half of the serve config's Web keys (`<hostname>.<suffix>:<port>`)
    # and of every attached app's tailnet address. Owner-provided like
    # the auth key, and for the same reason: with PVC state (§1) the
    # node's FQDN never leaves the pod — containerboot stores it only in
    # a kube state Secret this design deliberately does not use, and the
    # LocalAPI read that would observe it needs exec. The suffix is
    # visible to the owner in their admin console on every device name.
    attribute :tailnet_domain, :string do
      allow_nil?(false)
      public?(true)
      # DNS full-name bound: 253 chars, dot-separated lowercase labels.
      constraints(
        match: ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/,
        max_length: 253
      )
    end

    attribute :provider, FluxVale.Infrastructure.Types.AccessGatewayProvider do
      allow_nil?(false)
      default(:tailscale)
      public?(true)
    end

    attribute :state, FluxVale.Infrastructure.Types.AccessGatewayState do
      allow_nil?(false)
      default(:provisioning)
      public?(true)
    end

    # Friendly copy for the panel; technical detail stays here and is
    # admin-only (the #179 stance, same split as an instance's
    # status_message — never a k8s term on a customer surface).
    attribute :status_message, :string do
      public?(true)
    end

    # The Secret's NAME in the access namespace. Never the key. Opaque
    # to everything outside the provider implementation (ADR-0039 §2).
    attribute :credential_secret_ref, :string do
      public?(false)
    end

    # The Secret's NAME holding the org's Tailscale API token (ADR-0040
    # §5 — the tailnet-claiming trust surface, dns + routes scopes).
    # Same discipline as `credential_secret_ref`: the token itself never
    # reaches Postgres and no user surface reads it back. Nullable: a
    # gateway that never claimed needs no token.
    attribute :api_token_secret_ref, :string do
      public?(false)
    end

    # The tailnet claims this gateway holds (ADR-0040 §3): domain =>
    # resolver IP, one entry per claimed domain. The claim registry the
    # unclaim's shared-tailnet rule reads (one split-DNS route per
    # tailnet+domain serves all gateways). Written only through the
    # claim/unclaim funnels (system seams).
    attribute :dns_claims, :map do
      public?(false)
    end

    # #232's must-fix sibling (ADR-0039 §5): the settlement cursor. The
    # FIRST settle opens it; a suspend parks it exactly like an
    # instance's running anchor folds at a stop. Internal.
    attribute :metering_since, :utc_datetime_usec do
      public?(false)
    end

    # The live monthly rate this gateway bills at (cents). A snapshot by
    # design: the price the owner opted in at is the price they keep —
    # the instance grandfathered-* stance's simpler cousin, because a
    # gateway has one number and no allocation to re-price. Suspended
    # rows keep it so resume bills the same rate.
    attribute :monthly_cents, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0)
    end

    attribute :provisioned_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :needs_attention_since, :utc_datetime_usec do
      public?(false)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :organization, FluxVale.Accounts.Organization do
      allow_nil?(false)
      public?(true)
    end

    has_many :access_routes, AccessRoute do
      # The route's FK is `gateway_id` (see AccessRoute), not the
      # `access_gateway_id` Ash would derive from this relationship's
      # destination name.
      destination_attribute(:gateway_id)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      description("""
      Opts the org in (ADR-0039): writes the row as :provisioning and
      enqueues the cluster work. The hostname is minted here — opaque,
      never derived from org or app names (§1). The monthly rate is the
      caller's (the pricing lane's figure); the row stores it as the
      billing snapshot.
      """)

      accept([:organization_id, :monthly_cents, :tailnet_domain])

      # The org is the ACTOR's (the Instance create's contract): the
      # attribute stays acceptable for the actorless system path
      # (`authorize?: false`), but with an actor present this change
      # forces the actor's own org, so a member of a funded org can no
      # longer create a gateway owned by a different org (which that org
      # would then pay for), and `ActorOrgWalletFunded` and the row can
      # never disagree about whose wallet is in play.
      change({FluxVale.Infrastructure.Instance.SetOrganizationFromActor, []})

      change(GenerateHostname)

      # The provider's credential arrives as an argument, not a column:
      # provision writes it to the Secret and stores only the ref.
      argument(:auth_key, :string, allow_nil?: false, sensitive?: true)

      change(ProvisionCluster)
    end

    read :get_by_id do
      description("Get a gateway by id")
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    # The panel's and the operations' read: ONE gateway per org.
    read :get_for_organization do
      description("The org's gateway (at most one — `unique_organization`)")
      get?(true)
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end

    # The system-wide list the ladder walks (the instances' list stance:
    # unbounded + actorless, system seam only).
    read :list_all do
      description("Every gateway (the zero-balance ladder's input)")
    end

    update :update_credential do
      description("""
      Re-pastes the auth key — the NeedsLogin / deleted-node recovery
      (§4). Writes the Secret and restarts the pod so the new key lands
      as a fresh join; the row leaves :needs_attention for
      :provisioning and the observed-state write settles it.

      Also carries the tailnet-domain backfill: a row created before the
      column existed (or one whose owner retyped the suffix) re-renders
      its serve config here, so the recovery path is also the repair
      path.
      """)

      require_atomic?(false)
      accept([:tailnet_domain])
      argument(:auth_key, :string, allow_nil?: false, sensitive?: true)

      change(FluxVale.Infrastructure.AccessGateway.RepasteCredential)
    end

    # Observable-state write: the platform's read of the cluster, and
    # the ladder's suspend. System-only (policy above).
    update :update_state do
      description("System-only: observed gateway state + the panel's message.")

      require_atomic?(false)

      accept([
        :state,
        :status_message,
        :needs_attention_since,
        :metering_since,
        :provisioned_at,
        :credential_secret_ref
      ])
    end

    update :set_api_token_ref do
      description("System-only: the API-token Secret's ref on the row (authorize?: false).")
      accept([:api_token_secret_ref])
      require_atomic?(false)
    end

    update :update_claims do
      description("System-only: the gateway's tailnet claims map (authorize?: false).")
      accept([:dns_claims])
      require_atomic?(false)
    end

    # The observer's body — the trigger below drives it every minute.
    # Without this action the only promoter to :active was unreachable
    # from production code, so every row stayed :provisioning (no badge,
    # no accrual, no NeedsLogin recovery).
    update :perform_observe do
      description("""
      Reads the gateway's cluster state and writes the observation
      (ADR-0039 §2). The :observe trigger's body.
      """)

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, gateway ->
          FluxVale.Infrastructure.observe_access_gateway(gateway)
        end)
      end)
    end

    update :suspend do
      description("""
      The zero-balance ladder's gateway arm (#268's must-fix): scales the
      pod to 0 and parks the anchor. No accrual while suspended
      (ADR-0039 §5); the row and its Secret stay so resume is cheap.
      """)

      require_atomic?(false)
      accept([])

      change(FluxVale.Infrastructure.AccessGateway.Suspend)
    end

    update :resume do
      description(
        "The owner's funded resume after suspension — scale back to 1, reopen the anchor."
      )

      require_atomic?(false)
      accept([])

      change(FluxVale.Infrastructure.AccessGateway.Resume)
    end

    # Settlement's cursor write (the instance `settle_anchors` shape).
    update :settle_anchors do
      description(
        "System-only: the settlement cursor write (PerformSettle, under the wallet lock)."
      )

      accept([:metering_since])
      require_atomic?(false)
    end

    action :delete, :struct do
      description("""
      Opts the org out: tears the cluster objects down and hard-deletes
      the row (async; retries transient failures). Detaching every
      instance is part of teardown — an instance left attached to a
      vanished gateway would keep an unreachable serve route and a
      policy entry pointing at nothing.
      """)

      argument(:id, :uuid, allow_nil?: false, public?: true)
      constraints(instance_of: __MODULE__)

      run(fn input, %{actor: actor, authorize?: authorize?} ->
        case get_by_id(input.arguments.id, actor: actor, authorize?: authorize?) do
          {:ok, %{state: :destroying} = gateway} ->
            # Mid-teardown, or a teardown that exhausted its retries
            # (mark_teardown_error parks the row here so the billing
            # triggers cannot resurrect it). Re-enqueue: teardown is
            # idempotent (404-tolerant deletes) and detach-convergent, so
            # a duplicate attempt against a live job costs one wasted
            # pass, while NOT re-enqueueing leaves an exhausted removal
            # with no path forward at all.
            enqueue_teardown!(gateway)
            {:ok, gateway}

          {:ok, gateway} ->
            with {:ok, destroying} <-
                   update_state(gateway, %{state: :destroying, status_message: "Removing access"},
                     authorize?: false
                   ) do
              enqueue_teardown!(destroying)
              {:ok, destroying}
            end

          {:error, _reason} = error ->
            error
        end
      end)
    end

    update :perform_provision do
      description("The :provision trigger's body — the retry path for cluster objects.")
      require_atomic?(false)
      accept([])

      change(FluxVale.Infrastructure.AccessGateway.ProvisionCluster)
    end

    update :perform_settle do
      description("The :settle_usage trigger's body — see PerformSettle (#268).")
      require_atomic?(false)
      accept([])

      change(PerformSettle)
    end

    # The teardown trigger's terminal write: the hard delete, after the
    # cluster objects are gone. System-only (the trigger runs actorless);
    # the actor-facing opt-out is the :delete generic action above.
    destroy :destroy_after_teardown do
      description("System-only: the teardown's hard delete (authorize?: false)")
    end

    update :perform_teardown do
      description("The :teardown trigger's body — tears down cluster objects, then the row.")
      require_atomic?(false)
      accept([])

      change(PerformTeardown)
    end

    update :mark_provision_error do
      description("Error handler for :provision — unexpected job failures land :needs_attention.")
      require_atomic?(false)
      accept([])
      argument(:error, :map, allow_nil?: true)

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:state, :needs_attention)
        |> Ash.Changeset.force_change_attribute(
          :status_message,
          "Access setup failed unexpectedly — try connecting again"
        )
        |> Ash.Changeset.force_change_attribute(:needs_attention_since, DateTime.utc_now())
      end)
    end

    update :mark_teardown_error do
      description("""
      Error handler for :teardown — exhaustion keeps the row in
      :destroying with an honest message.

      Not :needs_attention: the :observe and :settle triggers both select
      that state, so a failed removal would be re-observed as a live
      gateway and start billing the org that just opted out. :destroying
      also keeps the teardown's ownership, and the :delete action
      re-enqueues from it (the owner's retry).
      """)

      require_atomic?(false)
      accept([])
      argument(:error, :map, allow_nil?: true)

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:state, :destroying)
        |> Ash.Changeset.force_change_attribute(
          :status_message,
          "Removal failed — retry removing access"
        )
      end)
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:create)
    define(:get_by_id, args: [:id])
    define(:get_for_organization, args: [:organization_id])
    define(:list_all)
    define(:update_credential)
    define(:update_state)
    define(:set_api_token_ref)
    define(:update_claims)
    define(:suspend)
    define(:resume)
    define(:delete, args: [:id])
    define(:perform_provision)
    define(:perform_settle)
    define(:perform_observe)
    define(:perform_teardown)
    define(:mark_provision_error)
    define(:mark_teardown_error)
  end

  identities do
    identity(:unique_organization, [:organization_id])

    # Two orgs must never mint the same gateway name — tailnet machine
    # names are unique per tailnet, but our own table is the first
    # collision surface (and the CT ledger's).
    identity(:unique_hostname, [:hostname])
  end

  # The record, not a changeset: AshOban reads the resource's trigger
  # DSL off the record's resource (the Instance teardown shape).
  defp enqueue_teardown!(gateway) do
    AshOban.run_trigger(gateway, :teardown)
  end

  # The instances attached to this gateway — teardown's detach list and
  # the settle's pairing sanity. `authorize?: false`: the ops seam.
  @doc false
  @spec attached_instances(t()) :: [Instance.t()]
  def attached_instances(%__MODULE__{id: gateway_id}) do
    AccessRoute
    |> Ash.Query.filter(gateway_id == ^gateway_id)
    |> Ash.Query.load(:instance)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.instance)
  end
end
