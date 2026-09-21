defmodule FluxVale.Catalog.Category do
  @moduledoc """
  Catalog grouping (e.g. Media) — seed- and admin-owned, never user-writable.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "categories"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy action_type(:read) do
      description "Any signed-in actor browses the catalog; public read arrives with M7 pages"
      authorize_if(actor_present())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description "Platform admins manage catalog categories (ADR-0027, ADR-0030)"
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
      constraints(match: ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/)
    end

    attribute :description, :string do
      public?(true)
    end

    attribute :icon, :string do
      public?(true)
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
      primary? true
      accept([:name, :slug, :description, :icon])
    end

    update :update do
      primary? true
      # slug is the identity seeds look up by — immutable after create.
      accept([:name, :description, :icon])
    end

    read :get_by_slug do
      description "Get a category by its slug"
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end
  end

  code_interface do
    domain FluxVale.Catalog

    define(:create)
    define(:get_by_slug, args: [:slug])
  end

  identities do
    identity(:unique_slug, [:slug])
    identity(:unique_name, [:name])
  end
end
