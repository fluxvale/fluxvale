defmodule FluxVale.Catalog.App do
  @moduledoc """
  App — the canonical catalog entry a user browses (e.g. Forgejo).

  Groups AppVersions; a specific version carries the deploy blueprint that
  seeds an Instance (#73).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  # #360 (ADR-0019 §1): the catalog's wire contract — the public browse
  # surface (ADR-00025); first cut is the authenticated read (every
  # /api/v1 route rides the auth pipeline).
  json_api do
    type("app")

    routes do
      # catalog:read
      index(:list,
        route: "/apps",
        default_fields: [
          :id,
          :name,
          :slug,
          :tagline,
          :description,
          :icon_url,
          :source_url,
          :docs_url,
          :file_access
        ]
      )

      # catalog:read — one segment in the path; the param name is the
      # action's own argument (`:slug` feeds it by name).
      get(:get_by_slug,
        route: "/apps/:slug",
        default_fields: [
          :id,
          :name,
          :slug,
          :tagline,
          :description,
          :icon_url,
          :source_url,
          :docs_url,
          :file_access
        ]
      )
    end
  end

  policies do
    policy action_type(:read) do
      description(
        "Public browse — the catalog is a public marketing surface (#164, ADR-00025); writes stay admin-only"
      )

      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Platform admins manage catalog apps (ADR-0027, ADR-0030)")
      authorize_if(always())
    end
  end

  postgres do
    table("apps")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
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

    attribute :tagline, :string do
      public?(true)
      constraints(max_length: 140)
    end

    attribute :description, :string do
      public?(true)
    end

    attribute :icon_url, :string do
      public?(true)
    end

    attribute :source_url, :string do
      public?(true)
    end

    attribute :docs_url, :string do
      public?(true)
    end

    # File access (#190, ADR-0035): instances of this app get the
    # WebDAV sidecar on their data volume. Catalog-declared, not a
    # deploy-time choice — every instance of the app gets it, and the
    # Instance snapshots the flag at create (DeriveFromAppVersion).
    attribute :file_access, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # Marketing metadata (#611 plan §4.1, S1): curated app truth the
    # page cannot derive, authored in the seed YAML. All optional —
    # omission is a designed state (plan §5), and every field stays
    # off the JSON:API default_fields lists in v1 (plan §3), so
    # nothing leaks onto the wire by accident. Nullable (not just
    # []-defaulted) because the OpenAPI artifact marks non-nullable
    # attributes schema-required, and required-but-absent would lie to
    # generated clients about the default responses.
    #
    # Honest limits, rendered in the hero's "Worth knowing" block.
    # 1-6 items when present, each 20-280 chars.
    attribute :caveats, {:array, :string} do
      default([])
      public?(true)
      constraints(max_length: 6, items: [min_length: 20, max_length: 280])
    end

    # The "an alternative to X and Y" positioning line, plus the FAQ's
    # "what does it replace" answer. Names only, max 5, 1-60 chars
    # each.
    attribute :alternatives, {:array, :string} do
      default([])
      public?(true)
      constraints(max_length: 5, items: [min_length: 1, max_length: 60])
    end

    # One line under the "in action" screenshots heading.
    attribute :in_action_intro, :string do
      public?(true)
      constraints(max_length: 160)
    end

    # The "in action" proof section (Types.ScreenshotList owns the
    # shape: 1-4 items, src/alt/caption, one enforcement point).
    attribute :screenshots, FluxVale.Catalog.Types.ScreenshotList do
      default([])
      public?(true)
    end

    # The 2x2 "what you can do" grid (Types.FeatureList owns the
    # shape, including the icon allowlist the renderer reuses).
    attribute :features, FluxVale.Catalog.Types.FeatureList do
      default([])
      public?(true)
    end

    # App-specific FAQ objections the generated FAQ cannot answer
    # (Types.FaqList owns the shape).
    attribute :faq, FluxVale.Catalog.Types.FaqList do
      default([])
      public?(true)
    end

    # Community link-row entry. https only — the public page must not
    # link plain http (\A/\z-anchored: one URL token, no trailing
    # junk, no trailing newline, which $ alone would admit).
    attribute :community_url, :string do
      public?(true)
      constraints(match: ~r/\Ahttps:\/\/\S+\z/)
    end
  end

  relationships do
    belongs_to :category, FluxVale.Catalog.Category do
      allow_nil?(false)
      public?(true)
    end

    has_many :app_versions, FluxVale.Catalog.AppVersion do
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :name,
        :slug,
        :tagline,
        :description,
        :icon_url,
        :source_url,
        :docs_url,
        :file_access,
        :caveats,
        :alternatives,
        :in_action_intro,
        :screenshots,
        :features,
        :faq,
        :community_url,
        :category_id
      ])

      # D10 at the plain-field seam (the typed lists enforce their own).
      validate(
        {FluxVale.Catalog.ValidateCopyRules, fields: [:caveats, :alternatives, :in_action_intro]}
      )
    end

    update :update do
      primary?(true)
      # Copy rules scan changed strings in Elixir — no atomic
      # expression (same stance as AppVersion's env validations).
      require_atomic?(false)
      # slug is the identity seeds look up by — immutable after create.
      accept([
        :name,
        :tagline,
        :description,
        :icon_url,
        :source_url,
        :docs_url,
        :file_access,
        :caveats,
        :alternatives,
        :in_action_intro,
        :screenshots,
        :features,
        :faq,
        :community_url,
        :category_id
      ])

      # D10 at the plain-field seam (the typed lists enforce their own).
      validate(
        {FluxVale.Catalog.ValidateCopyRules, fields: [:caveats, :alternatives, :in_action_intro]}
      )
    end

    read :get_by_slug do
      description("Get an app by its slug")
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end

    # #360: the browse list the catalog page reads through the category
    # relationship — the resource itself had no list action. Mirrors the
    # read policy's own posture exactly (action_type(:read) → public
    # browse, #164/ADR-00025): no policy is added or widened, this read
    # simply falls under the existing one. Sorted like the page sorts.
    read :list do
      description("The catalog's apps, by name — the browse surface's flat list")
      prepare(build(sort: :name))
    end
  end

  code_interface do
    domain(FluxVale.Catalog)

    define(:create)
    define(:update)
    define(:get_by_slug, args: [:slug])
    define(:list)
  end

  identities do
    identity(:unique_slug, [:slug])
    identity(:unique_name, [:name])
  end
end
