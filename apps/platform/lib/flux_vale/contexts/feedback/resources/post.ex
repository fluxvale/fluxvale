defmodule FluxVale.Feedback.Post do
  @moduledoc """
  Post — a feature request on the public feedback board (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../../../docs/adr/00026-feedback-board.md)).

  Reads are public (the board is a public, indexed surface); writes run
  the paying gate (ADR-0026 §2/§3): a create names an org and passes for
  its owner past the paid gate, a launch-allowlisted actor, or a platform
  admin — `FluxVale.Checks.ActorOwnsPaidOrg`. Content edits and the
  status workflow stay platform-admin-only (moderation). `slug` is the
  public URL stem, derived from the title at create and immutable after
  (ADR-0026 §4). `vote_count` is the cached counter the votes slice
  maintains (`Feedback.Vote`); `comment_count` stays a column until the
  comments slice. `tags` is the curated topical vocabulary (T10,
  `Feedback.Tag`), written only through the `:set_tags` moderation action.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Feedback,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Feedback.Post.AuthorStatusMail
  alias FluxVale.Feedback.Post.DeriveSlug
  alias FluxVale.Feedback.Post.RejectReferencedOriginal
  alias FluxVale.Feedback.Post.SetActorDefaults
  alias FluxVale.Feedback.Post.SetStatus

  @statuses [:open, :planned, :started, :completed, :duplicate, :declined]

  @doc """
  The declared status vocabulary — the board's single source for the
  public surface's filter chips, badges and labels (FeedbackHTML and
  FeedbackController derive from this; a new status lands here first).
  """
  @spec status_values() :: [atom()]
  def status_values, do: @statuses

  postgres do
    table("feedback_posts")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    custom_indexes do
      # Org-scoped views and queries are the near-term consumers
      # (moderation lists, an org's post pages). The write gate does
      # NOT read posts by org — it resolves memberships and the wallet.
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

      # The counter's race backstop (the same idiom): vote_count only
      # moves through the vote actions' SQL-atomic increments, so a bug
      # driving it negative is refused by the DB clause — the mapping
      # answers field-scoped, never a published negative count.
      check_constraint(:vote_count, "vote_count_non_negative",
        check: "vote_count >= 0",
        message: "must be zero or more"
      )

      # Same idiom, same reason, for the comments' counter.
      check_constraint(:comment_count, "comment_count_non_negative",
        check: "comment_count >= 0",
        message: "must be zero or more"
      )
    end
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
    # The cached counters ride the ignore list too (ADR-0048): they are
    # derivative data, recomputed from the Vote and Comment rows, so a
    # cast or comment can never put counter values in a version's diff.
    # The row itself is silenced by name via ignore_actions below —
    # 0.8.1's ignore_attributes filters the recorded diff, but the
    # write trigger is the changeset's changed? flag, which the bumps'
    # atomic updates set.
    ignore_attributes([:created_at, :updated_at, :vote_count, :comment_count])
    ignore_actions([:bump_vote_count, :bump_comment_count])
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
      description("Public board (ADR-0026 §2): anonymous and any actor read")

      authorize_if(always())
    end

    # THE paying gate (ADR-0026 §2/§3, ruled by the owner): a create
    # names an org and passes only for its owner past the paid gate —
    # or the launch-allowlist cohort, or a platform admin. The gate is
    # the create's alone: edits and the status workflow stay moderation
    # (the admin policy below).
    policy action_type(:create) do
      description(
        "The paying gate (ADR-0026 §2/§3): the named org's owner past the paid gate, launch-allowlisted, or admin"
      )

      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(FluxVale.Checks.ActorOwnsPaidOrg)
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description(
        "Platform admins moderate posts — update, set_status, destroy (creates pass the paying gate above)"
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
      # it — the org the write names, else the actor's personal org —
      # before validations run (the Instance derived-field pattern).
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

    # The topical vocabulary (T10): the join rows, then the read-side
    # many-to-many the board and the post page load. Written only
    # through :set_tags below (moderation).
    has_many :post_tags, FluxVale.Feedback.PostTag do
      public?(true)
    end

    many_to_many :tags, FluxVale.Feedback.Tag do
      through(FluxVale.Feedback.PostTag)
      public?(true)
      # Chip order is display order — alphabetical, everywhere.
      sort(name: :asc)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      # slug/created_by_user_id are derived, :status stays at its :open
      # default (a post is born open — statuses move through
      # :set_status). organization_id is the org the write NAMES (the
      # paying gate's subject — ActorOwnsPaidOrg answers on it),
      # defaulting to the actor's personal org in SetActorDefaults.
      accept([:title, :description])
      argument(:organization_id, :uuid, allow_nil?: true)

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

      # The author notification (T7) rides after the write: a FRESH
      # status move mails the author (the change owns the gates).
      change(AuthorStatusMail)
    end

    # The counters' maintenance writes (BumpPostVoteCount and
    # BumpPostCounter): dedicated actions so the paper trail can ignore
    # them by name (ignore_actions above) — the counters are derivative
    # data (ADR-0048). updated_at still moves on vote/comment activity
    # (any update touches the timestamp), so the sitemap's
    # re-crawl semantics are unchanged (the pinned test in
    # comment_test).
    update :bump_vote_count do
      description("Atomic vote-counter maintenance for Vote cast/retract — never versioned")

      accept([])
      require_atomic?(false)
    end

    update :bump_comment_count do
      description(
        "Atomic comment-counter maintenance for Comment create/destroy — never versioned"
      )

      accept([])
      require_atomic?(false)
    end

    update :set_tags do
      description("Moderation: replace the post's topical tags (T10)")

      # Tag ids, the curated vocabulary's identities — a dedicated
      # moderation action (one concern per action, the :set_status
      # shape), NOT an accepted field on :update: content edits and
      # tagging stay apart. append_and_remove makes the list the whole
      # truth: tags absent from it are untagged. Unknown ids fail the
      # write loudly (manage_relationship resolves each against Tag).
      # KNOWN GAP: no audit trail — unlike :set_status's stamps, WHO
      # tagged and WHEN is unrecorded. Revisit the day tag changes need
      # attribution (the join's created_at is its only trace today).
      argument(:tag_ids, {:array, :uuid}, allow_nil?: false, default: [])
      change(manage_relationship(:tag_ids, :tags, type: :append_and_remove))

      # manage_relationship drives join-row creates/destroys — Ash
      # cannot run it atomically; a single-row admin write, the trade
      # :set_status makes.
      require_atomic?(false)
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
    define(:set_tags)
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
