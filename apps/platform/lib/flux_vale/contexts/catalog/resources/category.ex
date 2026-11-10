defmodule FluxVale.Catalog.Category do
  @moduledoc """
  Catalog grouping (e.g. Media) — seed- and admin-owned, never user-writable.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("categories")
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
      description(
        "Public browse — the catalog is a public marketing surface (#164, ADR-00025); writes stay admin-only"
      )

      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Platform admins manage catalog categories (ADR-0027, ADR-0030)")
      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      # URL-shaped only — slug is the seed's idempotency key, so values a
      # get-or-create lookup could never match again are rejected at write.
      constraints(match: ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/)
    end

    attribute :description, :string do
      public?(true)
    end

    attribute :icon, :string do
      public?(true)
    end

    # Marketing metadata (#611 plan §4.2, S1): the "who is this for"
    # line every app page in the category renders — one authored
    # sentence per category instead of one per app. Optional; omission
    # omits the hero's audience paragraph.
    attribute :audience, :string do
      public?(true)
      constraints(max_length: 180)
    end
  end

  relationships do
    has_many :apps, FluxVale.Catalog.App do
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :slug, :description, :icon, :audience])

      # D10 at the plain-field seam (the typed lists enforce their own).
      validate({FluxVale.Catalog.ValidateCopyRules, fields: [:audience]})
    end

    update :update do
      primary?(true)
      # Copy rules scan the changed string in Elixir — no atomic
      # expression (same stance as AppVersion's env validations).
      require_atomic?(false)
      # slug is the identity seeds look up by — immutable after create.
      accept([:name, :description, :icon, :audience])

      # D10 at the plain-field seam (the typed lists enforce their own).
      validate({FluxVale.Catalog.ValidateCopyRules, fields: [:audience]})
    end

    read :get_by_slug do
      description("Get a category by its slug")
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end

    read :list_with_apps do
      description("The browse surfaces' category list: name-sorted with its apps loaded")
      prepare(build(sort: :name, load: [:apps]))
    end
  end

  code_interface do
    domain(FluxVale.Catalog)

    define(:create)
    define(:update)
    define(:get_by_slug, args: [:slug])
    define(:list_with_apps)
  end

  identities do
    identity(:unique_slug, [:slug])
    identity(:unique_name, [:name])
  end
end
