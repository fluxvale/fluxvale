defmodule FluxVale.Pricing.Size do
  @moduledoc """
  Size — a compute class (#125, storage decoupled by #558): a named
  CPU + memory shape and the flat monthly rate that shape costs while
  running. Storage is NOT part of a size (the #558 decoupling): it
  prices per gigabyte on its own axis, so the row carries no storage
  and no stopped rate — a stopped instance pays only for its storage
  (ADR-0028 §2), which a compute class cannot know.

  Seeded from the market anchor curve — the category's proven
  willingness-to-pay point (ADR-0028; the named source stays out of
  public code per ADR-0018 Am. 1); the calibration against the box COGS
  lives in docs/pricing-calibration.md. Slug is the seed's idempotency
  key; prices themselves are admin-editable business data (the operator
  console at /admin/catalog; the generated admin at /admin/ash stays as
  the debug fallback).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Pricing,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("pricing_sizes")
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
    # with today's semantics.
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

    policy action_type(:read) do
      # #164: the public catalog show page prices versions for anonymous
      # visitors (ADR-0028's $X.XX/mo, now on the marketing surface too).
      description(
        "Public browse — prices show on the public catalog (#164, ADR-00025); writes stay admin-only"
      )

      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Platform admins manage prices (ADR-0027, ADR-0030)")
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

    # The compute class's running rate. Storage prices on its own axis
    # (#558): no storage attribute, no stopped rate — stopped pays
    # storage only, which the class cannot know.
    attribute :monthly_cents, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:slug, :cpu_cores, :memory_mb, :monthly_cents])
    end

    update :update do
      primary?(true)
      # slug is the identity seeds look up by — immutable after create.
      accept([:cpu_cores, :memory_mb, :monthly_cents])

      # Single-row admin/seed write; ValidateAllocationFrozen probes
      # referencing versions, which can't be one atomic expression.
      require_atomic?(false)

      # before_action?: the probe must run inside the transaction so
      # its size-row lock holds to commit — at changeset time the lock
      # would evaporate at statement end (#543).
      validate(FluxVale.Pricing.Size.ValidateAllocationFrozen, before_action?: true)
    end

    read :get_by_slug do
      description("Get a size by its slug")
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end
  end

  code_interface do
    domain(FluxVale.Pricing)

    define(:create)
    define(:update)
    define(:get_by_slug, args: [:slug])
  end

  identities do
    identity(:unique_slug, [:slug])
  end
end
