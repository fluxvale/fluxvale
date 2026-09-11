defmodule FluxVale.Ops.AccessRule do
  @moduledoc """
  One allowlist row for platform access (ADR-0023 §1 + Am. 1): exactly one
  of `domain` / `email` — a row admits either an entire domain or one
  specific address. Semantics live in `FluxVale.Ops.AccessRules` (the only
  sanctioned evaluator): **empty table = unrestricted; any rows =
  allowlist** — the same mechanism flipped by data. Rows are admin-entered
  through AshAdmin at environment bring-up, never seeded (settled on #26;
  ADR-0023 Am. 5's empty-then-close).

  Mutations are platform-admin-only (AshAdmin rides the same policy) and
  bust the snapshot cache in an `after_action` hook — the mutating node
  sees its own change instantly; the 60s TTL bounds staleness elsewhere.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Ops,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "access_rules"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description "Platform admins manage access rules (ADR-0027, ADR-0030)"
      authorize_if(always())
    end

    # Everything else — including anonymous/default reads — is denied. The
    # evaluator's snapshot read runs authorize?: false (see
    # AccessRules.Cache): access rules are global config, not actor-scoped
    # data, so that read isn't an authorization question.
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :domain, :ci_string do
      public?(true)
      # Domain-shaped rows only — a row that can never match a real
      # address's domain would sit silently inert (same posture as
      # FeatureFlag's code-shaped key constraint). ci_string both directions:
      # matching is case-insensitive AND the unique index is too (CodeRabbit,
      # #48 — a differently-cased duplicate would be data integrity rot).
      constraints(match: ~r/^[a-z0-9.-]+\.[a-z]{2,}$/i)
    end

    attribute :email, :ci_string do
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary? true
      accept([:domain, :email])
      # Exactly one of domain/email — the Present builtin with exactly: 1
      validate(present([:domain, :email], exactly: 1))
      change(FluxVale.Ops.AccessRules.BustCache)
    end

    update :update do
      primary? true
      accept([:domain, :email])
      validate(present([:domain, :email], exactly: 1))
      change(FluxVale.Ops.AccessRules.BustCache)
      # The BustCache after_action hook can't run atomically — acceptable
      # for an operator CRUD resource: single-row, admin-driven, no hot path
      require_atomic?(false)
    end

    destroy :destroy do
      primary? true
      change(FluxVale.Ops.AccessRules.BustCache)
      require_atomic?(false)
    end
  end

  code_interface do
    domain FluxVale.Ops

    define(:create)
  end

  identities do
    identity(:unique_domain, [:domain])
    identity(:unique_email, [:email])
  end
end
