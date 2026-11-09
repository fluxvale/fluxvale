defmodule FluxVale.Ops.AccessRule do
  @moduledoc """
  One allowlist row, per purpose (ADR-0023 §1 + Am. 1; ADR-0026 §3):
  exactly one of `domain` / `email`, scoped to a `purpose`:

  - `:auth` — the platform entry gate (sign-in JIT, session/token
    presentation). Fail-OPEN on an empty table: empty = unrestricted
    (prod's pre-beta state; the staging gate and PAT auth depend on
    it).
  - `:feedback` — the feedback-board write gate's launch arm
    (ADR-0026 §3): the invite cohort until the first purchase exists.
    Fail-CLOSED on an empty table: empty = nobody allowlisted — an
    empty write-gate must not become an open gate.

  The opposite empty-table semantics are the point: entry defaults
  open, the write gate defaults shut. Semantics live in
  `FluxVale.Ops.AccessRules` (the only sanctioned evaluator). Rows are
  admin-entered through AshAdmin at environment bring-up, never seeded
  (settled on #26; ADR-0023 Am. 6's empty-then-close). Uniqueness is
  per (purpose, email) and (purpose, domain) — the same address can
  sit on both purposes.

  Mutations are platform-admin-only (AshAdmin rides the same policy) and
  bust the snapshot cache in an `after_action` hook — the mutating node
  sees its own change instantly; the 60s TTL bounds staleness elsewhere.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Ops,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("access_rules")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
  end

  # The audit trail (#645, ADR-0048): the plan's one config posture,
  # uniform across the business set as later slices adopt it, plus the
  # shared version mixin (indexes + actor label) and D7's
  # source-read-policy posture for version reads. Rationale lives in
  # the ADR, not here.
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

    belongs_to_actor(:user, FluxVale.Identity.User,
      domain: FluxVale.Identity,
      on_delete: :nilify
    )

    apply_can_read_policy?(true)
    mixin({FluxVale.PaperTrail.VersionMixin, :version_resource, []})
  end

  policies do
    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Platform admins manage access rules (ADR-0027, ADR-0030)")
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

    # The purpose the row admits for (ADR-0023 §1; ADR-0026 §3).
    # Declared atoms only — the one_of constraint rejects anything else
    # at the cast, so no input path ever builds an atom dynamically.
    attribute :purpose, :atom do
      allow_nil?(false)
      default(:auth)
      public?(true)
      constraints(one_of: [:auth, :feedback])
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:domain, :email, :purpose])
      # Exactly one of domain/email — the Present builtin with exactly: 1
      validate(present([:domain, :email], exactly: 1))
      change(FluxVale.Ops.AccessRules.BustCache)
    end

    update :update do
      primary?(true)
      accept([:domain, :email, :purpose])
      validate(present([:domain, :email], exactly: 1))
      change(FluxVale.Ops.AccessRules.BustCache)
      # The BustCache after_action hook can't run atomically — acceptable
      # for an operator CRUD resource: single-row, admin-driven, no hot path
      require_atomic?(false)
    end

    destroy :destroy do
      primary?(true)
      change(FluxVale.Ops.AccessRules.BustCache)
      require_atomic?(false)
    end
  end

  code_interface do
    domain(FluxVale.Ops)

    define(:create)
  end

  identities do
    # Per-purpose uniqueness: the same address may sit on both purposes,
    # but only one row per (purpose, shape) — a duplicate :feedback row
    # is data integrity rot, while an :auth row never collides with a
    # :feedback one.
    identity(:unique_domain, [:purpose, :domain])
    identity(:unique_email, [:purpose, :email])
  end
end
