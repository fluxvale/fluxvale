defmodule FluxVale.Accounts.Organization do
  @moduledoc """
  Organization — the ownership entity for platform resources (#119,
  ADR-0030): instances attach to it (the entitlement boundary), wallets
  attach to it (the billing boundary, M5), and it is the abuse boundary
  for per-org entitlements (welcome credits, #122).

  Every user gets a personal org at signup (JIT, creator = owner — see
  `FluxVale.Accounts.provision_personal_org/1`). `slug` is the stable
  handle (`[a-z0-9-]`, GitHub-style); `name` is display-only and carries
  no uniqueness — two orgs may be named alike, the slug cannot.

  Deliberately no JSON:API surface (v1 stance — backend model until a
  consumer needs one) and no AshAdmin (no support flow needs it yet).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Accounts.Membership

  postgres do
    table "organizations"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy action_type(:read) do
      description "Members read their organizations"
      authorize_if(relates_to_actor_via(:members))
    end

    policy action_type(:create) do
      description "Any signed-in actor creates organizations (JIT provisioning is a system op)"
      authorize_if(actor_present())
    end

    # Team features will gate destroy on the :owner role; today every
    # membership is :owner (provisioning only creates owners), so
    # member-level authorization is safe. Revisit trigger: the first
    # :member membership. No update action exists yet — the first
    # rename flow adds it.
    policy action_type(:destroy) do
      description "Members destroy their organizations"
      authorize_if(relates_to_actor_via(:members))
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
    end
  end

  relationships do
    has_many :memberships, Membership do
      public?(true)
    end

    many_to_many :members, FluxVale.Identity.User do
      through(Membership)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary? true
      accept([:name, :slug])
    end

    read :get_by_id do
      description "Get an organization by id"
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :get_by_slug do
      description "Get an organization by slug"
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end
  end

  code_interface do
    domain FluxVale.Accounts

    define(:create)
    define(:get_by_id, args: [:id])
    define(:get_by_slug, args: [:slug])
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  validations do
    validate(match(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/),
      on: :create,
      message: "must contain only lowercase alphanumeric characters and hyphens"
    )
  end
end
