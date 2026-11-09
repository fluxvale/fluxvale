defmodule FluxVale.Feedback.PostTag do
  @moduledoc """
  Join resource pairing a feedback post with a topical tag
  (fluxvale/fluxvale#412 T10): one pairing per (post, tag)
  (`unique_tag_per_post`). Rows are written only through `Post.set_tags`
  (the moderation action — the vocabulary is admin-curated), so the
  policies mirror Tag's: public reads (the board renders each post's
  chips), admin-only writes.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Feedback,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("feedback_post_tags")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # Both parents' FKs cascade (the Vote posture): the pairings are the
    # post's and the tag's dependent records — deleting either takes
    # them along in one statement.
    references do
      reference(:post, on_delete: :delete)
      reference(:tag, on_delete: :delete)
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
      description(
        "Pairings render on the public board (ADR-0026 §2): anonymous and any actor read"
      )

      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Tagging is moderation (T10): admins only, via Post.set_tags")

      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # Join rows never update — created_at is the only stamp worth keeping.
    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :post, FluxVale.Feedback.Post do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :tag, FluxVale.Feedback.Tag do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    # No update: a pairing exists or it doesn't (set_tags adds/removes rows).
    defaults([:read])

    # Explicit accept: the default create's accept would miss the
    # belongs_to source attributes (they are not writable by default —
    # the Vote/Membership shape).
    create :create do
      primary?(true)
      accept([:post_id, :tag_id])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  code_interface do
    domain(FluxVale.Feedback)

    define(:create)
    define(:read)
    define(:destroy)
  end

  identities do
    # The unique composite index on (post_id, tag_id) IS this identity —
    # one pairing per post per tag, enforced at the DB (post_id leading
    # also serves the board's per-post chip reads).
    identity(:unique_tag_per_post, [:post_id, :tag_id])
  end
end
