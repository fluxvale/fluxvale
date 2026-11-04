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

  policies do
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
