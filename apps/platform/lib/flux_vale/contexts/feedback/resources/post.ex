defmodule FluxVale.Feedback.Post do
  @moduledoc """
  Post — a feature request on the public feedback board (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../../../docs/adr/00026-feedback-board.md)).

  Reads are public (the board is a public, indexed surface); every write
  is platform-admin-only this slice — the paying-customer gate is slice 2,
  deliberately not built here. `slug` is the public URL stem, derived from
  the title at create and immutable after (ADR-0026 §4). `vote_count` /
  `comment_count` are cached counters — columns only now; the slices that
  mint votes and comments maintain them.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Feedback,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Feedback.Post.DeriveSlug
  alias FluxVale.Feedback.Post.RejectReferencedOriginal
  alias FluxVale.Feedback.Post.SetActorDefaults
  alias FluxVale.Feedback.Post.SetStatus

  @statuses [:open, :planned, :started, :completed, :duplicate, :declined]

  postgres do
    table("feedback_posts")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    custom_indexes do
      # Slice 2's gate axis: the paying check reads the actor's org's
      # posts, so every gate query is a lookup on this column.
      index([:organization_id])

      # The duplicate-merge lookup: which post points at the original.
      index([:duplicate_of_id])
    end

    check_constraints do
      # The row-local mirror of SetStatus's guards: a post is a
      # duplicate exactly when it carries the pointer. The new table is
      # empty — no backfill concern. The DB clause is the race backstop;
      # the change is the front door.
      check_constraint(:status, "status_matches_duplicate_of",
        check: "(status = 'duplicate') = (duplicate_of_id IS NOT NULL)",
        message: "must carry duplicate_of_id exactly when status is duplicate"
      )
    end
  end

  policies do
    policy action_type(:read) do
      description(
        "Public board (ADR-0026 §2): anonymous and any actor read; writes stay admin-gated this slice"
      )

      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description(
        "Platform admins write posts this slice (the paying gate is ADR-0026 §2, a later slice)"
      )

      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 4, max_length: 140)
    end

    # Derived from the title at create (DeriveSlug), never accepted —
    # URLs are sticky (ADR-0026 §4).
    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, max_length: 140)
    end

    attribute :description, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 5000)
    end

    # The moderation workflow (ADR-0026 §1). Declared atoms only — the
    # one_of constraint rejects anything else at the cast, so no input
    # path ever builds an atom dynamically.
    attribute :status, :atom do
      allow_nil?(false)
      default(:open)
      public?(true)
      constraints(one_of: @statuses)
    end

    # Cached counters (ADR-0026 §1): the vote/comment slices maintain
    # them; the columns land first so those slices are additive.
    attribute :vote_count, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :comment_count, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    # The status workflow's audit trail — WHO and WHEN last moved it
    # (SetStatus stamps both; the author-notification slice reads them).
    attribute :status_changed_by_user_id, :uuid do
      public?(true)
    end

    attribute :status_changed_at, :utc_datetime_usec do
      public?(true)
    end
  end

  relationships do
    belongs_to :organization, FluxVale.Accounts.Organization do
      # allow_nil? true + presence validation: SetActorDefaults resolves
      # it from the actor before validations run (the Instance
      # derived-field pattern).
      public?(true)
    end

    belongs_to :created_by_user, FluxVale.Identity.User do
      public?(true)
    end

    # Set when the status moves to :duplicate — the duplicate points at
    # the post it folds into (ADR-0026 §1). Self-reference and
    # duplicate-of-duplicate are rejected in SetStatus; row existence is
    # the FK's business.
    belongs_to :duplicate_of, FluxVale.Feedback.Post do
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      # slug/organization_id/created_by_user_id are derived or defaulted,
      # never accepted; :status stays at its :open default (a post is
      # born open — statuses move through :set_status).
      accept([:title, :description])

      change(SetActorDefaults)
      change(DeriveSlug)
    end

    update :update do
      primary?(true)

      # Content edits only: slug is create-time identity, :status moves
      # through :set_status (its audit stamps), the counters belong to
      # their own slices, and ownership doesn't move.
      accept([:title, :description])
    end

    update :set_status do
      description("Move a post through the moderation workflow (ADR-0026 §1)")

      # :duplicate_of_id rides the accepted attribute; the :status
      # argument is applied to the attribute declaratively (the change
      # guards both directions and stamps the audit trail).
      accept([:duplicate_of_id])
      argument(:status, :atom, allow_nil?: false, constraints: [one_of: @statuses])
      change(set_attribute(:status, arg(:status)))

      # SetStatus is a function change — Ash cannot run it atomically;
      # a single-row admin write, the trade Organization's rename already
      # makes.
      require_atomic?(false)
      change(SetStatus)
    end

    destroy :destroy do
      primary?(true)

      # Day-one AshAdmin click: destroying an original that duplicates
      # point at must answer field-scoped, not with an Ecto constraint
      # crash (RejectReferencedOriginal is a function change). The FK
      # stays the race backstop.
      require_atomic?(false)
      change(RejectReferencedOriginal)
    end
  end

  code_interface do
    domain(FluxVale.Feedback)

    define(:create)
    define(:update)
    define(:set_status)
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  validations do
    # The derived-field pattern (see :organization above): the presence
    # answer for an actor with no org is this field-scoped message, not
    # a bare Forbidden from the policy gate.
    validate(present(:organization_id), on: :create, message: "is required")
  end
end
