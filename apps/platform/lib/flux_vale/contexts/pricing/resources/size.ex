defmodule FluxVale.Pricing.Size do
  @moduledoc """
  Size — a priceable allocation envelope (#125): the flat monthly rate a
  running instance pays (ADR-0028's price = f(allocation)) plus the
  storage-only fee while stopped (ADR-0028 §2).

  Seeded from the market anchor curve — the category's proven
  willingness-to-pay point (ADR-0028; the named source stays out of
  public code per ADR-0018 Am. 1); the calibration against the box COGS
  lives in docs/pricing-calibration.md. Slug is the seed's idempotency
  key; prices themselves are admin-editable business data (AshAdmin).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Pricing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "pricing_sizes"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy action_type(:read) do
      description "Any signed-in actor sees prices (ADR-0028's live $X.XX/mo)"
      authorize_if(actor_present())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description "Platform admins manage prices (ADR-0027, ADR-0030)"
      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      # URL-shaped only — slug is the seed's idempotency key (see Category).
      constraints(match: ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/)
    end

    attribute :cpu_cores, :decimal do
      allow_nil?(false)
      public?(true)
      # A size exists to run something — a zero-core envelope is not a size.
      constraints(greater_than: 0)
    end

    attribute :memory_mb, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    # 0 is legal: config-only apps on a ~100 MB overlay (the anchor's floor).
    attribute :storage_gb, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0)
    end

    # Integer US cents — 1 credit = 1 US cent (docs/product.md).
    attribute :monthly_cents, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0)
    end

    attribute :stopped_monthly_cents, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary? true
      accept([:slug, :cpu_cores, :memory_mb, :storage_gb, :monthly_cents, :stopped_monthly_cents])
    end

    update :update do
      primary? true
      # slug is the identity seeds look up by — immutable after create.
      accept([:cpu_cores, :memory_mb, :storage_gb, :monthly_cents, :stopped_monthly_cents])

      # Single-row admin/seed write; ValidateAllocationFrozen probes
      # referencing versions, which can't be one atomic expression.
      require_atomic?(false)

      validate(FluxVale.Pricing.Size.ValidateAllocationFrozen)
    end

    read :get_by_slug do
      description "Get a size by its slug"
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end
  end

  code_interface do
    domain FluxVale.Pricing

    define(:create)
    define(:update)
    define(:get_by_slug, args: [:slug])
  end

  identities do
    identity(:unique_slug, [:slug])
  end
end
