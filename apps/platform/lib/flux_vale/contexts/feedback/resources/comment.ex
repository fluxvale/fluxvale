defmodule FluxVale.Feedback.Comment do
  @moduledoc """
  Comment — a reply on a feedback-board post (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../../../docs/adr/00026-feedback-board.md)).

  The gate is the owner's Nov ruling for comments specifically: **any
  authenticated user may comment** — registered non-payers included,
  membership and paying status irrelevant (this deliberately departs from
  ADR-0026 §2's paying-customer gate for votes/posts; comments open the
  conversation). Anonymous stays read-only. Reads are public; the only
  write besides create is admin destroy (moderation) — no update action
  exists at all and no author self-delete: a ruled scope decision, not an
  oversight (a slice that adds editing owns the moderation story for it).

  `author_user_id` derives from the actor and is never accepted input.
  `Post.comment_count` is the cached aggregate this resource maintains
  (`BumpPostCounter`, atomic at the SQL level).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Feedback,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Feedback.Comment.AuthorUsername
  alias FluxVale.Feedback.Comment.BodyHtml
  alias FluxVale.Feedback.Comment.BumpPostCounter
  alias FluxVale.Feedback.Comment.SetAuthorFromActor

  postgres do
    table("feedback_comments")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # on_delete :delete on the post FK (the same posture votes use):
    # comments are the post's dependent records — moderation's delete
    # takes them along in one statement (no orphaned threads, and the
    # counter's row IS the post, so no drift).
    references do
      reference(:post, on_delete: :delete)
    end

    custom_indexes do
      # One comment per (post, author, body) — the seed identity,
      # enforced at the DB (#508, the unique_vote_per_org posture):
      # two concurrent seeding runs used to both find zero comments for
      # one triple and both mint, and the duplicate then failed every
      # later seed pass on find_comment's corruption guard.
      #
      # body rides md5(): a max-length (5000-char) body exceeds the
      # btree row-size ceiling as a raw key, and a hash key is
      # deterministic on the exact bytes, so the identity stays
      # exact-match — the same `==` find_comment matches with (:string,
      # not ci_string). Identity semantics and find semantics are one
      # thing, which is what lets a race loser converge on the winner's
      # row instead of tripping the index with a body the find calls
      # distinct.
      #
      # post_id leads, so the index also serves every "comments for
      # this post" read — the standalone post_id index this resource
      # used to carry retires with it (the Vote shape).
      index([:post_id, :author_user_id, "md5(body)"],
        unique: true,
        name: "feedback_comments_unique_body_per_post_author_index",
        error_fields: [:body]
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
        "Public board (ADR-0026 §2): comments are publicly readable, anonymous included"
      )

      authorize_if(always())
    end

    policy action_type(:create) do
      description(
        "Any authenticated user may comment (the owner's Nov ruling for #412: membership/paying irrelevant; anonymous stays read-only)"
      )

      authorize_if(actor_present())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description(
        "Moderation (ADR-0026 Am. 1): platform admins destroy comments; no author edit or author delete in this slice"
      )

      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :body, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 5000)
    end
  end

  relationships do
    belongs_to :post, FluxVale.Feedback.Post do
      allow_nil?(false)
      public?(true)
    end

    # The actor at create time — never accepted (SetAuthorFromActor).
    belongs_to :author_user, FluxVale.Identity.User do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      # post comes from the caller, author from the actor — never from
      # input.
      accept([:post_id, :body])

      change(SetAuthorFromActor)
      change({BumpPostCounter, by: 1})
    end

    destroy :destroy do
      primary?(true)

      # Moderation only (admins). The counter give-back is a function
      # change, so the action cannot run atomically.
      require_atomic?(false)
      change({BumpPostCounter, by: -1})
    end
  end

  code_interface do
    domain(FluxVale.Feedback)

    define(:create)
  end

  calculations do
    calculate :author_username, :string do
      calculation(AuthorUsername)

      # The one author projection safe for the anonymous board read:
      # the handle the author published by commenting (the User record
      # itself stays admin-read — see AuthorUsername).
      description("The author's public handle")
      public?(true)
    end

    calculate :body_html, :string do
      calculation(BodyHtml)

      # The body through Feedback.Markdown (#488) — computed at read so
      # the sanitization posture applies to stored rows, and loaded with
      # the list so island re-renders never re-parse Markdown.
      description("The body rendered to sanitized HTML")
      public?(true)
    end
  end
end
