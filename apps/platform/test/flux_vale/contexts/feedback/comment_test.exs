defmodule FluxVale.Feedback.CommentTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias Ash.Error.Changes.Required
  alias Ash.Error.Invalid.NoSuchInput
  alias Ash.Resource.Info
  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Comment.BumpPostCounter
  alias FluxVale.Feedback.Comment.SetAuthorFromActor
  alias FluxVale.Feedback.Post
  alias FluxVale.TestSupport.AccountsFixtures

  # Precondition posture (mirrors seeds + PostTest): the fixture post is
  # created `authorize?: false` — a precondition the admin gate would
  # otherwise make every test carry an admin for. Comment fixtures go
  # through the real action WITH their author: the create policy admits
  # any actor, so no bypass, and author derivation is part of the
  # contract under test.
  defp post! do
    Post.create!(
      %{
        title: "Commented post #{System.unique_integer([:positive])}",
        description: "A fixture post"
      },
      actor: admin(),
      authorize?: false
    )
  end

  defp comment!(post, author, attrs \\ %{}) do
    params = Map.merge(%{body: "A fixture comment"}, attrs)
    Comment.create!(%{post_id: post.id, body: params.body}, actor: author)
  end

  defp count(post_id) do
    post = Ash.get!(Post, post_id, authorize?: false)
    post.comment_count
  end

  defp admin, do: AccountsFixtures.platform_admin!()
  defp regular, do: AccountsFixtures.user!()

  describe "policies — reads" do
    test "an anonymous visitor reads comments" do
      post = post!()
      comment!(post, regular(), %{body: "Publicly readable"})

      assert {:ok, rows} = Ash.read(Comment)
      assert Enum.any?(rows, &(&1.body == "Publicly readable"))
    end

    test "any signed-in actor reads comments" do
      post = post!()
      comment!(post, regular())

      assert {:ok, rows} = Ash.read(Comment, actor: regular())
      assert Enum.any?(rows, &(&1.post_id == post.id))
    end
  end

  describe "policies — create" do
    test "an anonymous create is Forbidden, not a field error" do
      # ACTUAL behavior, verified against the vendored Ash source (see
      # SetAuthorFromActor's moduledoc for the full pipeline order): the
      # changeset-build require-values pass covers accept-list attributes
      # only and author_user_id is derived, never accepted, so the
      # changeset reaches authorize still valid and the actor_present()
      # policy answers first — the total refusal. Post answers
      # field-scoped only because of its explicit
      # present(:organization_id) validation, which Comment has no twin
      # of. Nothing is written either way.
      post = post!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Comment.create(%{post_id: post.id, body: "anon"}, authorize?: true)

      assert count(post.id) == 0
    end

    test "a plain registered non-paying user comments (membership/paying irrelevant)" do
      post = post!()
      # user!/1 is a registered user with no wallet purchase: the gate
      # must not ask for either an org or a payment.
      user = regular()

      assert {:ok, comment} =
               Comment.create(%{post_id: post.id, body: "First!"}, actor: user)

      assert comment.author_user_id == user.id
      assert comment.post_id == post.id
      assert comment.body == "First!"
    end

    test "an orgless-authed user comments" do
      # Ash.seed! — the only way to produce an org-less user: the create
      # action's JIT change always provisions one (state actions can't
      # produce, the documented seed! exception). Comments need no org,
      # so the gate must admit them.
      post = post!()

      orgless =
        Ash.Seed.seed!(FluxVale.Identity.User, %{
          email: "orgless-#{System.unique_integer()}@fluxvale.test"
        })

      assert {:ok, comment} =
               Comment.create(%{post_id: post.id, body: "No org, still here"}, actor: orgless)

      assert comment.author_user_id == orgless.id
    end

    test "the author is derived from the actor, never accepted" do
      # Pinned: supplying author_user_id is rejected as a NO SUCH INPUT —
      # the field is not on the accept list, so an impostor cannot even
      # propose it; the author is the actor or the create dies.
      post = post!()
      author = regular()
      impostor = regular()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Comment.create(
                 %{post_id: post.id, body: "Mine", author_user_id: impostor.id},
                 actor: author
               )

      assert Enum.any?(errors, &match?(%NoSuchInput{input: :author_user_id}, &1))

      assert {:ok, comment} =
               Comment.create(%{post_id: post.id, body: "Mine"}, actor: author)

      assert comment.author_user_id == author.id
    end
  end

  describe "policies — destroy" do
    test "an author (any non-admin) cannot destroy; only platform admins moderate" do
      post = post!()
      comment = comment!(post, regular())

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(comment, actor: regular())
      assert {:ok, _still_there} = Ash.get(Comment, comment.id, authorize?: false)

      assert :ok = Ash.destroy(comment, actor: admin())
    end

    test "an anonymous destroy is Forbidden and the counter is unchanged" do
      post = post!()
      comment = comment!(post, regular())

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(comment)
      assert count(post.id) == 1
    end

    test "a Forbidden destroy leaves the counter unchanged" do
      post = post!()
      comment = comment!(post, regular())

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(comment, actor: regular())
      assert count(post.id) == 1
    end

    test "no update action exists at all (no author edit this slice)" do
      # The ruled scope decision, pinned: a slice that adds editing must
      # do so deliberately, not by flipping a default.
      refute Info.action(Comment, :update)
      actions = Info.actions(Comment)
      refute Enum.any?(actions, &(&1.type == :update))
    end
  end

  describe "counter cache" do
    test "create bumps the post's comment_count (+1)" do
      post = post!()
      assert count(post.id) == 0

      comment!(post, regular())
      assert count(post.id) == 1
    end

    test "two comments and one admin destroy leave the counter at one" do
      post = post!()
      first = comment!(post, regular())
      comment!(post, regular())
      assert count(post.id) == 2

      assert :ok = Ash.destroy(first, actor: admin())
      assert count(post.id) == 1
    end

    test "a refused create does not bump the counter" do
      post = post!()

      assert {:error, %Ash.Error.Invalid{}} =
               Comment.create(
                 %{post_id: post.id, body: String.duplicate("x", 5001)},
                 actor: regular()
               )

      assert count(post.id) == 0
    end

    test "comment activity moves post.updated_at (activity-updated semantics)" do
      # Pinned per the architect's decision: a commented post IS changed
      # content and the board's sitemap lastmod reads updated_at, so the
      # bump riding Post's generic :update (moving the timestamp) is
      # correct — see BumpPostCounter's moduledoc before changing it in
      # either direction.
      post = post!()
      {:ok, before} = Ash.get(Post, post.id, authorize?: false)

      comment!(post, regular())

      {:ok, after_comment} = Ash.get(Post, post.id, authorize?: false)

      assert DateTime.compare(after_comment.updated_at, before.updated_at) == :gt
    end

    test "a bump that fails after the hook refuses the whole write (rollback, not drift)" do
      # Ash.seed! — the precondition (a comment whose post claims zero
      # comments) is only producible by bypassing the counter: through
      # actions the row and the count move as one unit, so no action
      # path creates this state (the documented seed! exception).
      post =
        Ash.Seed.seed!(Post, %{
          title: "Zero count #{System.unique_integer([:positive])}",
          slug: "zero-count-#{System.unique_integer([:positive])}",
          description: "Seeded with a lying counter"
        })

      comment =
        Ash.Seed.seed!(Comment, %{
          post_id: post.id,
          author_user_id: admin().id,
          body: "The count lies"
        })

      # The -1 bump violates comment_count_non_negative AFTER the
      # before_action hook ran: the destroy dies with it and neither row
      # moves (the transaction claim in BumpPostCounter, exercised).
      assert {:error, %Ash.Error.Invalid{}} = Ash.destroy(comment, actor: admin())

      assert {:ok, kept} = Ash.get(Comment, comment.id, authorize?: false)
      assert kept.id == comment.id
      assert kept.body == "The count lies"
      assert count(post.id) == 0
    end
  end

  describe "references" do
    test "a comment for a missing post is refused field-scoped (not an FK crash)" do
      # The BumpPostCounter lookup answers before the DB's FK could —
      # the FK stays as the race backstop (the SetStatus stance).
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Comment.create(%{post_id: Ash.UUID.generate(), body: "x"}, actor: regular())

      assert Enum.any?(
               errors,
               &(&1.field == :post_id and
                   &1.message == "must reference an existing post")
             )
    end
  end

  describe "body constraints" do
    test "bounds answer at the cast, field-pinned" do
      post = post!()

      # The floor's actual answer: Ash treats "" as an empty value at the
      # cast, so it dies as the required check, not the min-length
      # message (the min_length: 1 constraint stays as the belt — a
      # length-zero string can never reach the data layer).
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Comment.create(%{post_id: post.id, body: ""}, actor: regular())

      assert Enum.any?(errors, &match?(%Required{field: :body}, &1))

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Comment.create(
                 %{post_id: post.id, body: String.duplicate("x", 5001)},
                 actor: regular()
               )

      assert Enum.any?(
               errors,
               &(&1.field == :body and
                   &1.message == "length must be less than or equal to %{max}")
             )
    end

    test "the 5000-char ceiling itself is accepted" do
      post = post!()

      assert {:ok, comment} =
               Comment.create(
                 %{post_id: post.id, body: String.duplicate("x", 5000)},
                 actor: regular()
               )

      assert String.length(comment.body) == 5000
    end
  end

  describe "change declarations" do
    test "the function changes declare non-atomic (destroy carries require_atomic? false)" do
      refute SetAuthorFromActor.atomic?()
      refute BumpPostCounter.atomic?()
    end
  end

  describe "author projection" do
    test "an anonymous reader loads the public author_username" do
      post = post!()
      author = regular()
      comment = comment!(post, author)

      assert {:ok, loaded} = Ash.load(comment, :author_username)
      assert loaded.author_username == author.username
    end

    test "the projection rides the anonymous board read" do
      post = post!()
      author = regular()
      comment!(post, author, %{body: "Render my handle"})

      assert {:ok, rows} = Ash.read(Comment, load: [:author_username])

      assert Enum.any?(
               rows,
               &(&1.body == "Render my handle" and &1.author_username == author.username)
             )
    end

    test "loading the author_user relationship directly stays Forbidden for anonymous" do
      # The projection boundary, pinned from both sides: the HANDLE is
      # public (the author published it by commenting), the User record
      # is not (its reads are admin-only). AuthorUsername resolves
      # authorize-free under that documented stance; the relationship
      # itself must not silently open for the anonymous board read.
      post = post!()
      comment = comment!(post, regular())

      assert {:error, %Ash.Error.Forbidden{}} = Ash.load(comment, :author_user)
    end
  end

  describe "post deletion takes its comments (cascade)" do
    test "destroying a post with comments succeeds and the comments are gone" do
      post = post!()
      comment = comment!(post, regular())

      # Moderation deletes the post; the comments are its dependent
      # records (on_delete :delete on the FK) — one statement, no count
      # drift, because the counter's row is the post itself.
      assert :ok = Ash.destroy(post, actor: admin())

      # Only the specific comment is asserted gone: the zero-count
      # fixture in the rollback test commits via Ash.seed! and stays
      # visible to this test's read (committed rows ignore the sandbox).
      assert {:error, _gone} = Ash.get(Comment, comment.id, authorize?: false)
    end
  end
end
