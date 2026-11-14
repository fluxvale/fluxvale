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
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshPaperTrail.Resource]

  # #700: the sort-key seam — the grammar pattern and the create change
  # live in the child module; aliased so both read short below.
  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Catalog.AppVersion.SetSortKey

  # #360 (ADR-0019 §1): the version family's wire contract — the detail
  # page's blueprint summary, same public surface the page renders.
  json_api do
    type("app_version")

    routes do
      # catalog:read
      index(:list_for_app,
        route: "/apps/:app_id/versions",
        default_fields: [
          :id,
          :app_id,
          :version,
          :image,
          :port,
          :healthcheck_path,
          :storage_mount_path,
          :oidc_callback_path,
          :default_cpu_cores,
          :default_memory_mb,
          :default_storage_gb,
          :default_env_vars,
          :configurable_env_vars,
          :first_run,
          :oidc_wiring,
          :backing_services,
          :release_notes,
          :published_at,
          :monthly_cents
        ]
      )

      # catalog:read
      get(:get_by_id,
        route: "/app-versions/:id",
        default_fields: [
          :id,
          :app_id,
          :version,
          :image,
          :port,
          :healthcheck_path,
          :storage_mount_path,
          :oidc_callback_path,
          :default_cpu_cores,
          :default_memory_mb,
          :default_storage_gb,
          :default_env_vars,
          :configurable_env_vars,
          :first_run,
          :oidc_wiring,
          :backing_services,
          :release_notes,
          :published_at,
          :monthly_cents
        ]
      )

      # catalog:read — #770: the version's default-size rates (the
      # recommended Size row's compute rate plus the storage axis at the
      # version's own default), the manual's truthful monthly/stopped
      # figure. The price is computed server-side, never in a client.
      route(:get, "app-versions/:id/quote", :default_quote)
    end
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
      # Public read includes the blueprint attrs (image, env vars,
      # healthcheck) — catalog data is upstream-shaped and public. Never
      # put a secret in default_env_vars; a secret-carrying app version
      # needs a secret ref, which revisits this policy.
      description(
        "Public browse — the catalog is a public marketing surface (#164, ADR-00025); writes stay admin-only"
      )

      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Platform admins manage catalog app versions (ADR-0027, ADR-0030)")
      authorize_if(always())
    end

    # #770: the default-ramp quote is public catalog arithmetic — the
    # same public posture as the version reads.
    policy action(:default_quote) do
      description(
        "Public default-size quote — the same public posture as the version reads (#164)"
      )

      authorize_if(always())
    end
  end

  postgres do
    table("app_versions")
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

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    # The grammar (X.Y.Z triples + one optional -suffix) lives in
    # SetSortKey — the constraint is what makes every stored version
    # keyable (#700).
    attribute :version, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: SetSortKey.pattern())
    end

    # #700: the semver-newest-first sort column — lexicographic on
    # this key equals semantic order (SetSortKey owns the encoding
    # and the grammar decision). Written once at create; version is
    # immutable after, so it can never drift.
    attribute :sort_key, :string do
      allow_nil?(false)
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

    # Where the deployer mounts the instance's data PVC (#189) —
    # blueprint, like image/port. Most apps keep their state on the
    # volume root; Kavita (#189) resolves its config dir from the
    # container's working directory (`/kavita`), so its SQLite DB only
    # persists when the volume lands at `/kavita/config`. Defaults to
    # "/data"; a version with `default_storage_gb` 0 never gets a mount.
    attribute :storage_mount_path, :string do
      allow_nil?(false)
      default("/data")
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

    # Env var the deploy fills with the instance's hostname when the app
    # validates Host headers (Django-class ALLOWED_HOSTS): the app would
    # otherwise 400 every request from its real name. Filled when the
    # default hostname is LIVE on a claimed domain — public rows always,
    # private rows per ADR-0040 §7's designed exception to ADR-0038 §4's
    # omission rule. nil = not wanted. No seed sets it yet — opt-in per
    # catalog app; the first consumer app sets it in its blueprint.
    attribute :host_allowlist_env, :string do
      public?(true)
      constraints(match: ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end

    # The app's OIDC callback path, as an identity provider needs it at
    # client registration (#511): Pocket ID only redirects to the
    # callback URLs listed on its client, and the exact path is the
    # mistyped-URL failure class its own troubleshooting names first.
    # The instance's public URL prefixes the stored path (the ingress
    # URL isn't catalog data — the ROOT_URL reasoning), so this carries
    # the path only. nil = the version exposes no OIDC consumer surface
    # (opt-in per catalog app, the instance_url_env precedent; the
    # identity provider itself — Pocket ID — is the nil case).
    attribute :oidc_callback_path, :string do
      public?(true)
      constraints(match: ~r{^/[\w/.-]*$})
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

    # How this app becomes usable on first open (#181, ADR-0034):
    # pattern + guaranteed env posture + locked-out keys + owner-facing
    # guidance, one generalized field for every catalog app. nil = no
    # posture needed (usable out of the box). Contract keys are the
    # contract's alone (ValidateFirstRunEnv keeps the env-var maps
    # disjoint); DeriveFromAppVersion applies `env` above every
    # deploy-time layer and rejects user values that touch either half.
    attribute :first_run, FluxVale.Catalog.Types.FirstRunContract do
      public?(true)
    end

    # The OIDC wiring recipe (#597): presence = this version can be
    # wired to an org's Pocket ID automatically — which env names the
    # wiring writes, whether the minted client gets PKCE. Per-version
    # like oidc_callback_path (an upstream breaking change never
    # re-wires older instances). The recipe's env names must exist in
    # this version's configurable_env_vars (ValidateOidcWiringEnv);
    # nil = no automatic wiring (Pocket ID itself, D4). Public read
    # carries names only, never secret values — the
    # oidc_callback_path stance.
    attribute :oidc_wiring, FluxVale.Catalog.Types.OidcWiring do
      public?(true)
    end

    # Bundled backing services (#612, ADR-0045): presence = this
    # version deploys with Postgres/Redis containers inside the
    # instance's own pod (the deployer's S2 renders them; here it is
    # blueprint only). [] = none (every existing entry; opt-in per
    # version, the oidc_wiring stance). Registry membership + env
    # ownership are validated at write time (ValidateBackingServices);
    # public read carries names only — kind, major, and url_env — no
    # values exist at catalog level (the oidc_callback_path stance).
    attribute :backing_services, {:array, FluxVale.Catalog.Types.BackingService} do
      allow_nil?(false)
      default([])
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

    # Curated prose under the version on the app page — D10 copy rules
    # at write time (#678, the ValidateCopyRules wiring in the actions).
    # The bound rides the pattern every ValidateCopyRules field carries
    # (audience 180, in_action_intro 160); 600 is the longest shipped
    # entry (424) with headroom.
    attribute :release_notes, :string do
      public?(true)
      constraints(max_length: 600)
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
      primary?(true)

      accept([
        :version,
        :image,
        :port,
        :healthcheck_path,
        :storage_mount_path,
        :instance_url_env,
        :host_allowlist_env,
        :oidc_callback_path,
        :default_env_vars,
        :configurable_env_vars,
        :first_run,
        :oidc_wiring,
        :backing_services,
        :default_cpu_cores,
        :default_memory_mb,
        :default_storage_gb,
        :release_notes,
        :published_at,
        :recommended_size_id,
        :app_id
      ])

      validate(present(:recommended_size_id))

      # #700: stamp the sort key from the (grammar-conforming) version.
      change(SetSortKey)

      # before_action?: the locked size read must run inside the
      # transaction or its FOR UPDATE evaporates at statement end
      # (#543).
      validate(FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation, before_action?: true)
      validate(FluxVale.Catalog.AppVersion.ValidateFirstRunEnv)
      validate(FluxVale.Catalog.AppVersion.ValidateOidcWiringEnv)
      validate(FluxVale.Catalog.AppVersion.ValidateBackingServices)
      # D10 at the plain-field seam (#678, the App create stance).
      validate({FluxVale.Catalog.ValidateCopyRules, fields: [:release_notes]})
    end

    update :update do
      primary?(true)
      # version is the seed's lookup key (with app_id) — immutable after
      # create, same as Category/App slug; an edited version would orphan
      # the row from seed convergence. Seeds converge drifted rows through
      # this action (run twice, zero dupes, data matches YAML).
      accept([
        :image,
        :port,
        :healthcheck_path,
        :storage_mount_path,
        :instance_url_env,
        :host_allowlist_env,
        :oidc_callback_path,
        :default_env_vars,
        :configurable_env_vars,
        :first_run,
        :oidc_wiring,
        :backing_services,
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

      # before_action?: same as create — the locked size read must
      # hold to commit (#543).
      validate(FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation, before_action?: true)
      validate(FluxVale.Catalog.AppVersion.ValidateFirstRunEnv)
      validate(FluxVale.Catalog.AppVersion.ValidateOidcWiringEnv)
      validate(FluxVale.Catalog.AppVersion.ValidateBackingServices)
      # D10 at the plain-field seam (#678, the App update stance).
      validate({FluxVale.Catalog.ValidateCopyRules, fields: [:release_notes]})
    end

    # #360: the detail page reads versions through the app relationship;
    # the resource itself had no by-id or per-app list read. Both mirror
    # the read policy's own posture exactly (action_type(:read) → public
    # browse): no policy added or widened.
    read :get_by_id do
      description("Get a version by id")
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :list_for_app do
      description("The app's versions, newest first")
      argument(:app_id, :uuid, allow_nil?: false)
      filter(expr(app_id == ^arg(:app_id)))
      # #700: semver-newest-first via the maintained key — every
      # surface that reads versions orders on sort_key (SetSortKey
      # owns the grammar and the encoding).
      prepare(build(sort: [sort_key: :desc]))
    end

    # #770: the default-size rates over the wire — the version's
    # recommended Size row plus the storage axis at its own default
    # (`Pricing.version_rates/1`), the same figure settlement charges
    # a default-size instance. A version with no recommended size is
    # the unpriced drift shape: a loud refusal, never a guessed price.
    action :default_quote, :map do
      description("The version's default-size monthly and stopped rates.")

      argument(:id, :uuid, allow_nil?: false, public?: true)

      run(fn input, context ->
        with {:ok, version} <-
               get_by_id(input.arguments.id,
                 actor: context.actor,
                 authorize?: context.authorize?
               ),
             {:ok, version} <-
               Ash.load(version, :recommended_size,
                 actor: context.actor,
                 authorize?: context.authorize?
               ) do
          case FluxVale.Pricing.version_rates(version) do
            nil ->
              {:error,
               InvalidArgument.exception(message: "the version carries no recommended size")}

            rates ->
              {:ok,
               %{
                 version_id: version.id,
                 cpu_cores: version.default_cpu_cores,
                 memory_mb: version.default_memory_mb,
                 storage_gb: version.default_storage_gb,
                 monthly_cents: rates.monthly_cents,
                 stopped_monthly_cents: rates.stopped_monthly_cents,
                 monthly: FluxVale.Pricing.format_monthly_rate(rates.monthly_cents),
                 stopped:
                   FluxVale.Pricing.format_usd(rates.stopped_monthly_cents) <> " while stopped"
               }}
          end
        end
      end)
    end
  end

  code_interface do
    domain(FluxVale.Catalog)

    define(:create)
    define(:update)
    define(:get_by_id, args: [:id])
    define(:list_for_app, args: [:app_id])
  end

  identities do
    identity(:unique_version_per_app, [:version, :app_id])
  end

  calculations do
    # #765: the recommended size's monthly running rate, so an agent
    # can quote the spend before it deploys. Billing's own figure —
    # never a second pricing path.
    calculate :monthly_cents, :integer, FluxVale.Catalog.AppVersion.MonthlyRate do
      public?(true)
    end
  end
end
