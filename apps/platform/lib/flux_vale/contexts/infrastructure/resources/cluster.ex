defmodule FluxVale.Infrastructure.Cluster do
  @moduledoc """
  A Kubernetes cluster customer instances can land on (ADR-0006): the
  schema treats multi-region as real from day one while exactly one
  cluster runs.

  `kubeconfig_ref` nil is the sentinel for **local**: the app
  authenticates in-cluster via its mounted service account (ADR-0020) —
  a stored kubeconfig for the cluster the pod runs in would duplicate
  credentials that rotate ~hourly. A populated ref names a remote
  cluster; the ref format is decided when one actually arrives (ADR-0016
  managed-k8s trigger; ADR-0006 Am. 2).

  The k8s client does not route through this row in M3 (#72) — its job
  is being Instance's FK target, making "which cluster does this
  namespace live on" a query instead of a future migration. Revisit when
  the second row exists.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("clusters")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
  end

  # The audit trail (#645, ADR-0048): the plan's one complete config
  # posture — the mixin line is mandatory (it carries the read policy,
  # the indexes, the actor label). version_extensions attaches the
  # Policy authorizer that policy rides on. Rationale lives in the
  # ADR, not here.
  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    sensitive_attributes(:redact)
    ignore_attributes([:created_at, :updated_at])
    reference_source?(false)
    create_version_on_destroy?(true)
    operation_id_field(:operation_id)
    mixin({FluxVale.PaperTrail.VersionMixin, :version_resource, []})
    version_extensions(authorizers: [Ash.Policy.Authorizer])

    belongs_to_actor(:user, FluxVale.Identity.User,
      domain: FluxVale.Identity,
      on_delete: :nilify
    )
  end

  policies do
    # The blanket authority (#644, ADR-0047): platform admins see and do
    # everything — but never through the machine API (the second
    # condition), so PAT callers fall through to the policies below
    # with today's semantics. Replaces the former blanket admin policy
    # (the bypass subsumes it for every non-PAT caller).
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

    # Everything else — anonymous and non-admin reads included — is denied.
    # Internal callers (seeds, the deploy flow #74) read with
    # authorize?: false: cluster placement is global config, not
    # actor-scoped data (same posture as AccessRule).
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      # Slug-shaped only — name is the seed's idempotency key and the
      # region-routing lookup key (v1's ResolveClusterFromRegion,
      # ADR-0006), so values a get-or-create lookup could never match
      # again are rejected at write.
      constraints(match: ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/)
    end

    attribute :kubeconfig_ref, :string do
      public?(true)
      # nil ⇒ local, in-cluster SA auth (see moduledoc) — deliberately
      # unconstrained until a second cluster fixes the ref format.
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :kubeconfig_ref])
    end

    update :update do
      primary?(true)
      # name is the lookup key — immutable after create.
      accept([:kubeconfig_ref])
    end

    read :get_by_name do
      description("Get a cluster by its name")
      get?(true)
      argument(:name, :string, allow_nil?: false)
      filter(expr(name == ^arg(:name)))
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:create)
    define(:update)
    define(:get_by_name, args: [:name])
  end

  identities do
    identity(:unique_name, [:name])
  end
end
