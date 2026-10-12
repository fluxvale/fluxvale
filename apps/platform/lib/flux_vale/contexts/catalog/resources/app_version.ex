defmodule FluxVale.Catalog.AppVersion do
  @moduledoc """
  AppVersion — a concrete deployable version of an App.

  Carries the deploy blueprint (image, port, probe path, env vars, resource
  defaults) a one-click deploy copies onto a new Instance (#73):
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

    # HTTP path the deployer's readiness/startup probes hit (#71); #73 threads
    # it into the Deployment manifest. "/" covers apps without a dedicated
    # health endpoint.
    attribute :healthcheck_path, :string do
      allow_nil?(false)
      default("/")
      public?(true)
      constraints(match: ~r{^/[\w/.-]*$})
    end

    # Env var the #73 deploy op fills with the instance's public URL
    # (https://<subdomain>.<base-domain>/): the ingress URL isn't catalog
    # data, but apps like Forgejo need it (FORGEJO__server__ROOT_URL) to
    # generate correct absolute links behind the proxy. nil = not wanted.
    attribute :instance_url_env, :string do
      public?(true)
      constraints(match: ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
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

    # The priced unit this version sells (#125, ADR-0028) — every version
    # names one (`present` validation below) and
    # ValidateSizeMatchesAllocation keeps it equal to the defaults here,
    # so provisioning's quota and billing's price describe one allocation.
    # DB column stays nullable: pre-#125 rows only heal via seed
    # convergence, never a NOT NULL backfill of catalog data.
    belongs_to :recommended_size, FluxVale.Pricing.Size do
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
        :healthcheck_path,
        :instance_url_env,
        :default_env_vars,
        :configurable_env_vars,
        :default_cpu_cores,
        :default_memory_mb,
        :default_storage_gb,
        :release_notes,
        :published_at,
        :recommended_size_id,
        :app_id
      ])

      validate(present(:recommended_size_id))
      validate(FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation)
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
        :healthcheck_path,
        :instance_url_env,
        :default_env_vars,
        :configurable_env_vars,
        :default_cpu_cores,
        :default_memory_mb,
        :default_storage_gb,
        :release_notes,
        :published_at,
        :recommended_size_id
      ])

      # Single-row admin/seed write; ValidateSizeMatchesAllocation reads
      # the referenced size, which can't be one atomic expression.
      require_atomic?(false)

      validate(present(:recommended_size_id))
      validate(FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation)
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
