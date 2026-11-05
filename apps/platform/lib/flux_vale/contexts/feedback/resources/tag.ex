defmodule FluxVale.Feedback.Tag do
  @moduledoc """
  Tag — a curated topical label on the feedback board (fluxvale/fluxvale#412
  T10, PikaPods-style): `platform`, `app-request`, plus one tag per
  catalog app slug (catalog apps are seeded INTO the vocabulary, so a
  post about Kavita carries the kavita tag and the vocabulary subsumes
  the catalog-app association). A tag whose slug matches a catalog app's
  slug renders the /apps/:slug cross-link on the post page (the display
  convention, FeedbackController).

  Reads are public — the board renders the vocabulary and filters by it.
  Every mutation is platform-admin-only: the vocabulary is curated, there
  is no user-facing create/update surface, and AshAdmin rides the same
  policies. `slug` is authored or derived from the name at create (the
  post slug's sanitize rules, Post.DeriveSlug.sanitize/1) and immutable
  after — ?tag= links in the wild are sticky, the post-slug rule.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Feedback,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Feedback.Tag.DeriveSlug

  postgres do
    table("feedback_tags")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
  end

  policies do
    policy action_type(:read) do
      description("Public vocabulary (ADR-0026 §2): anonymous and any actor read")

      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("The vocabulary is curated (T10): admins create, rename, and remove tags")

      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 2, max_length: 140)
    end

    # The board's ?tag= param and the catalog cross-link's match key.
    # Same shape rule as the post slug; max 50 — tags are vocabulary, not
    # titles.
    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, max_length: 50)
    end
  end

  relationships do
    has_many :post_tags, FluxVale.Feedback.PostTag do
      public?(true)
    end

    many_to_many :posts, FluxVale.Feedback.Post do
      through(FluxVale.Feedback.PostTag)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      # slug may be authored (a curated stem) or left to DeriveSlug —
      # allow_nil_input keeps an absent slug off the build-time required
      # check (the derive hook runs before the write; the run-time check
      # and the DB NOT NULL backstop a still-nil or unparsable slug).
      accept([:name, :slug])
      allow_nil_input([:slug])
      change(DeriveSlug)
    end

    update :update do
      primary?(true)

      # The display name is the only editable field: ?tag= links ride the
      # slug, so it stays create-time identity (the post slug's rule).
      accept([:name])
    end

    destroy :destroy do
      primary?(true)

      # Removing a tag takes its pairings along at the DB (the join's
      # on_delete :delete) — the same dependent-records posture the
      # post delete has.
    end

    read :get_by_slug do
      description("Get a tag by its slug — the board filter's lookup")
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end
  end

  code_interface do
    domain(FluxVale.Feedback)

    # create for the seed's get-or-create (the Category/App shape);
    # update and destroy have no non-admin callers — AshAdmin drives
    # them through Ash.get!/Ash.Changeset.
    define(:create)
    define(:get_by_slug, args: [:slug])
  end

  identities do
    identity(:unique_slug, [:slug])
  end
end
