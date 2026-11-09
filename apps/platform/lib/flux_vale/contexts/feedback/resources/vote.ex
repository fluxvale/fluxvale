defmodule FluxVale.Feedback.Vote do
  @moduledoc """
  Vote — an org's upvote on a feedback post (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../../../docs/adr/00026-feedback-board.md)): one
  vote per org per post (`unique_vote_per_org`), cast by a user but
  OWNED by the org — the cast runs the paying gate
  (`FluxVale.Checks.ActorOwnsPaidOrg`): the org's owner past the paid
  gate, a launch-allowlisted actor, or a platform admin. Mere members
  of a paid org get nothing; retract runs the same gate. Reads are
  public — counts are public data — but the board never counts live:
  `Post.vote_count` is the cached column this resource maintains
  atomically (BumpPostVoteCount), so reads ride the cached count.
  `cast_by_user_id` is attribution for moderation, not an ownership
  claim.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Feedback,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Feedback.Vote.BumpPostVoteCount
  alias FluxVale.Feedback.Vote.SetCastDefaults

  postgres do
    table("feedback_votes")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # on_delete :delete on the post FK (the PAT-precedent posture): the
    # votes are the post's dependent records — moderation's delete
    # takes them along in one statement (blocking the delete on fifty
    # retracts is not a workflow, and the counter's row IS the post, so
    # no drift).
    references do
      reference(:post, on_delete: :delete)
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
      description("Counts are public data (ADR-0026 §2): anonymous and any actor read")

      authorize_if(always())
    end

    # The paying gate, both write directions: the org's owner past the
    # paid gate, the launch-allowlist cohort, or a platform admin.
    policy action_type(:create) do
      description(
        "The paying gate (ADR-0026 §2/§3): the named org's owner past the paid gate, launch-allowlisted, or admin"
      )

      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(FluxVale.Checks.ActorOwnsPaidOrg)
    end

    policy action_type(:destroy) do
      description("Retract runs the same gate as cast (ADR-0026 §2)")

      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(FluxVale.Checks.ActorOwnsPaidOrg)
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :post, FluxVale.Feedback.Post do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :organization, FluxVale.Accounts.Organization do
      # allow_nil? true + presence validation: SetCastDefaults resolves
      # it — the org the write names, else the actor's personal org —
      # before validations run (the Post derived-field pattern).
      public?(true)
    end

    belongs_to :cast_by_user, FluxVale.Identity.User do
      # Attribution for moderation (ADR-0026 §1) — stamped from the
      # actor, not accepted; the org owns the vote, not the caster.
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :cast do
      description("Cast the org's vote on a post (one vote per org per post)")

      # post_id is what the write targets; organization_id is the org
      # whose slot it spends (the paying gate's subject), defaulted to
      # the actor's personal org in SetCastDefaults.
      accept([:post_id])
      argument(:organization_id, :uuid, allow_nil?: true)

      change(SetCastDefaults)
      change({BumpPostVoteCount, by: 1})
    end

    destroy :retract do
      description("Retract the org's vote (same gate as cast)")

      # Primary: AshAdmin's row delete button rides it (the moderation
      # path — ADR-0026 Am. 1).
      primary?(true)

      # BumpPostVoteCount is a function change — Ash cannot run it
      # atomically; a single-row gated write, the trade Post's
      # :set_status makes.
      require_atomic?(false)
      change({BumpPostVoteCount, by: -1})
    end
  end

  code_interface do
    domain(FluxVale.Feedback)

    define(:cast)

    # The island's retract rides the seam like cast (T5); AshAdmin's
    # row delete keeps the primary :destroy.
    define(:retract)
  end

  identities do
    # The unique composite index on (post_id, organization_id) IS this
    # identity — one vote per org per post, enforced at the DB (the
    # identity's unique index; post_id leading also serves the board's
    # per-post reads).
    identity(:unique_vote_per_org, [:post_id, :organization_id])
  end

  validations do
    # The derived-field pattern (see :organization above): the presence
    # answer for an actor with no org is this field-scoped message, not
    # a bare Forbidden from the policy gate.
    validate(present(:organization_id), on: :create, message: "is required")
  end
end
