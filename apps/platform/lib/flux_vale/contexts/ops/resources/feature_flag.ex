defmodule FluxVale.Ops.FeatureFlag do
  @moduledoc """
  A feature flag row — evaluated through `FluxVale.Ops.FeatureFlags`, never
  read ad hoc (ADR-0023 §2).

  Fail-closed by construction: a missing row means *disabled everywhere* —
  new behavior is off in prod before any seed exists. `rollout_percentage`
  nil = everyone when enabled; an integer 0–100 gates stickily per user.

  Lifecycle: a flag is deleted — row **and** code branch — once behavior is
  permanent; flags gate features, never schema (ADR-0010 rule). Keys are
  code-shaped snake_case so every row can match a declared
  `FeatureFlags.@known_flags` atom.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Ops,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "feature_flags"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description "Platform admins manage feature flags (ADR-0027, ADR-0030)"
      authorize_if(always())
    end

    # Everything else — including anonymous/default reads — is denied. The
    # evaluator's own lookup runs authorize?: false (see FeatureFlags): flags
    # are global config, not actor-scoped data, so that read isn't an
    # authorization question.
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :key, :string do
      allow_nil?(false)
      public?(true)
      # Code-shaped keys only: a row that can never match a declared
      # @known_flags atom would sit silently inert — reject it at write time
      # (AshAdmin included) instead.
      constraints(match: ~r/^[a-z0-9_]+$/)
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :rollout_percentage, :integer do
      public?(true)
      # nil = everyone when enabled (ADR-0023 §2); 0 = nobody, 100 = everyone.
      constraints(min: 0, max: 100)
    end

    attribute :description, :string do
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary? true
      accept([:key, :enabled, :rollout_percentage, :description])
    end

    update :update do
      primary? true
      accept([:key, :enabled, :rollout_percentage, :description])
    end

    # Evaluator lookup — runs authorize?: false from FeatureFlags, so this
    # action exists for that one call site, not for general use.
    read :by_key do
      description "Get a flag by its key"
      get?(true)
      argument(:key, :string, allow_nil?: false)
      filter(expr(key == ^arg(:key)))
    end
  end

  code_interface do
    domain FluxVale.Ops

    define(:create, args: [:key])
    define(:by_key, args: [:key])
  end

  identities do
    identity(:unique_key, [:key])
  end
end
