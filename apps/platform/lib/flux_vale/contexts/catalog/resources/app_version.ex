defmodule FluxVale.Catalog.AppVersion do
  @moduledoc """
  AppVersion — a concrete deployable version of an App.

  Carries the deploy blueprint (image, port, env vars, resource defaults)
  a one-click deploy copies onto a new Instance (#73):
  `default_env_vars` always ship; `configurable_env_vars` (typed by
  `EnvVarSchema`) is what a user may set at deploy time, validated against
  the spec at Instance creation.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "app_versions"
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
      description "Platform admins manage catalog app versions (ADR-0027, ADR-0030)"
      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :version, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :image, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :port, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1, max: 65_535)
    end

    # Always-shipped env (operator-owned; deployer stringifies values).
    attribute :default_env_vars, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :configurable_env_vars, FluxVale.Catalog.Types.EnvVarSchema do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :default_cpu_cores, :decimal do
      allow_nil?(false)
      default(Decimal.new("0.5"))
      public?(true)
    end

    attribute :default_memory_mb, :integer do
      allow_nil?(false)
      default(256)
      public?(true)
    end

    attribute :default_storage_gb, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :release_notes, :string do
      public?(true)
    end

    attribute :published_at, :utc_datetime_usec do
      public?(true)
    end
  end

  relationships do
    belongs_to :app, FluxVale.Catalog.App do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary? true

      accept([
        :version,
        :image,
        :port,
        :default_env_vars,
        :configurable_env_vars,
        :default_cpu_cores,
        :default_memory_mb,
        :default_storage_gb,
        :release_notes,
        :published_at,
        :app_id
      ])
    end

    update :update do
      primary? true
      # version is the seed's lookup key (with app_id) — immutable after
      # create, same as Category/App slug; an edited version would orphan
      # the row from seed convergence. Seeds converge drifted rows through
      # this action (run twice, zero dupes, data matches YAML).
      accept([
        :image,
        :port,
        :default_env_vars,
        :configurable_env_vars,
        :default_cpu_cores,
        :default_memory_mb,
        :default_storage_gb,
        :release_notes,
        :published_at
      ])
    end
  end

  code_interface do
    domain FluxVale.Catalog

    define(:create)
    define(:update)
  end

  identities do
    identity(:unique_version_per_app, [:version, :app_id])
  end
end
