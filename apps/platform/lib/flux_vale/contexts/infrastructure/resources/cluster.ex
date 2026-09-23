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
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "clusters"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description "Platform admins manage clusters (ADR-0027, ADR-0030)"
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
      primary? true
      accept([:name, :kubeconfig_ref])
    end

    update :update do
      primary? true
      # name is the lookup key — immutable after create.
      accept([:kubeconfig_ref])
    end

    read :get_by_name do
      description "Get a cluster by its name"
      get?(true)
      argument(:name, :string, allow_nil?: false)
      filter(expr(name == ^arg(:name)))
    end
  end

  code_interface do
    domain FluxVale.Infrastructure

    define(:create)
    define(:update)
    define(:get_by_name, args: [:name])
  end

  identities do
    identity(:unique_name, [:name])
  end
end
