defmodule FluxVale.Seeds.FeedbackSeedTest do
  @moduledoc """
  The feedback seed flow (`FluxVale.Seeds.seed_feedback!`, #412 T4)
  against a sandboxed DB — the shipped starter entries, statuses moved
  through the real action, demo votes and comments minted as REAL rows
  through the vote/comment actions so counters agree with visible
  content (#471), counter convergence for posts an earlier run already
  seeded, get-or-create idempotency, and the entry guards driven by
  fixture entries (the seed_catalog!/1 shape). The T10 tag vocabulary
  (`seed_tags!/0`) and the demo entries' tag pairings ride the same
  file.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.PostTag
  alias FluxVale.Feedback.Tag
  alias FluxVale.Feedback.Vote
  alias FluxVale.Identity.User
  alias FluxVale.Seeds
  alias FluxVale.TestSupport.FeedbackFixtures

  require Ash.Query

  defp tag_slugs do
    Tag
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.slug)
    |> MapSet.new()
  end

  defp tags_on!(post_slug) do
    post =
      Post
      |> Ash.Query.filter(slug == ^post_slug)
      |> Ash.read_one!(authorize?: false)
      |> Ash.load!(:tags, authorize?: false)

    post.tags
    |> Enum.map(& &1.slug)
    |> Enum.sort()
  end

  defp vote_rows_for!(post_id) do
    Vote
    |> Ash.Query.filter(post_id == ^post_id)
    |> Ash.count!(authorize?: false)
  end

  defp comment_rows_for!(post_id) do
    Comment
    |> Ash.Query.filter(post_id == ^post_id)
    |> Ash.count!(authorize?: false)
  end

  describe "seed_tags!/0 (the curated vocabulary)" do
    test "seeds the platform and app-request pair" do
      assert :ok == Seeds.seed_tags!()

      expected = MapSet.new(["platform", "app-request"])
      assert MapSet.subset?(expected, tag_slugs())
    end

    test "one tag per catalog app slug — the catalog seeds INTO the vocabulary" do
      # The shipped catalog rides pricing (versions reference a size).
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()
      assert :ok == Seeds.seed_tags!()

      expected = MapSet.new(["forgejo", "kavita"])
      assert MapSet.subset?(expected, tag_slugs())

      kavita =
        Tag
        |> Ash.Query.filter(slug == "kavita")
        |> Ash.read_one!(authorize?: false)

      assert kavita.name == "Kavita"
    end

    test "idempotent — re-running creates no duplicates and never converges admin renames" do
      assert :ok == Seeds.seed_admin!()
      assert :ok == Seeds.seed_tags!()

      first =
        Tag
        |> Ash.read!(authorize?: false)
        |> Enum.count()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)

      platform =
        Tag
        |> Ash.Query.filter(slug == "platform")
        |> Ash.read_one!(authorize?: false)

      Ash.update!(platform, %{name: "Renamed by an admin"}, actor: admin, authorize?: false)

      assert :ok == Seeds.seed_tags!()

      after_second =
        Tag
        |> Ash.read!(authorize?: false)
        |> Enum.count()

      assert after_second == first

      renamed =
        Tag
        |> Ash.Query.filter(slug == "platform")
        |> Ash.read_one!(authorize?: false)

      assert renamed.name == "Renamed by an admin"
    end
  end

  describe "seed_feedback!/0 (shipped entries)" do
    # The shipped entries carry tags (T10), and the tagging raises on an
    # unknown slug — the promotable seed's real order for the feedback
    # slice: the catalog first (the app tags enumerate its rows), then
    # the vocabulary, then the gated posts.
    defp seed_feedback_with_vocabulary! do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()
      assert :ok == Seeds.seed_tags!()
      assert :ok == Seeds.seed_feedback!()
    end

    test "seeds starter posts covering every status" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      by_slug = fn slug ->
        Post
        |> Ash.Query.filter(slug == ^slug)
        |> Ash.read_one!(authorize?: false)
      end

      # One entry per workflow status: completed, planned, started,
      # duplicate, declined, open (two).
      for {slug, status} <- [
            {"terraform-provider-for-instance-management", :completed},
            {"show-cost-estimates-in-the-deploy-wizard", :planned},
            {"alert-on-failing-health-checks", :started},
            {"cheaper-storage-for-backup-archives", :duplicate},
            {"bring-back-weekly-usage-emails", :declined},
            {"s3-backed-offsite-backup-exports", :open},
            {"suspend-an-instance-from-the-cli", :open}
          ] do
        post = by_slug.(slug)
        assert post, "expected #{slug} seeded"
        assert post.status == status, "expected #{slug} to be #{status}"
      end

      # The duplicate points at its original through the real pointer.
      dup = by_slug.("cheaper-storage-for-backup-archives")
      original = by_slug.("s3-backed-offsite-backup-exports")
      assert dup.duplicate_of_id == original.id

      # The counters agree with the rows that back them (#471): demo
      # activity is minted through the real actions, so a displayed
      # count is never a number without content behind it.
      terraform = by_slug.("terraform-provider-for-instance-management")
      assert terraform.vote_count > 0
      assert terraform.vote_count == vote_rows_for!(terraform.id)
      assert terraform.comment_count > 0
      assert terraform.comment_count == comment_rows_for!(terraform.id)
      assert dup.vote_count == vote_rows_for!(dup.id)
      assert dup.comment_count == comment_rows_for!(dup.id)
    end

    test "demo comments are real rows with resolvable handles" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      terraform =
        Post
        |> Ash.Query.filter(slug == "terraform-provider-for-instance-management")
        |> Ash.read_one!(authorize?: false)

      comments =
        Comment
        |> Ash.Query.filter(post_id == ^terraform.id)
        |> Ash.Query.load(:author_username)
        |> Ash.read!(authorize?: false)

      assert length(comments) == terraform.comment_count

      # Each body non-empty, each handle resolves to a real username.
      for comment <- comments do
        assert comment.body != ""
        assert is_binary(comment.author_username) and comment.author_username != ""
      end
    end

    test "backdates display timestamps; open posts stay unmoved" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      moved =
        Post
        |> Ash.Query.filter(slug == "alert-on-failing-health-checks")
        |> Ash.read_one!(authorize?: false)

      # A moved post carries a past status_changed_at (the "Started N
      # days ago" render); a fresh board must not read all "just now".
      assert DateTime.compare(moved.status_changed_at, DateTime.utc_now()) == :lt
      assert DateTime.compare(moved.created_at, DateTime.utc_now()) == :lt

      fresh =
        Post
        |> Ash.Query.filter(slug == "suspend-an-instance-from-the-cli")
        |> Ash.read_one!(authorize?: false)

      # A post that never moved keeps the nil signal ("Posted N ago").
      assert is_nil(fresh.status_changed_at)
    end
  end

  describe "seed_feedback!/1 (fixture entries — the guards)" do
    test "a title that derives off the authored slug fails naming both slugs" do
      assert :ok == Seeds.seed_admin!()

      entry = %{
        slug: "authored-slug",
        title: "Completely different words here",
        description: "x",
        status: :open,
        votes: 0,
        comments: [],
        age_days: 1,
        status_age_days: 0
      }

      error = assert_raise(RuntimeError, fn -> Seeds.seed_feedback!([entry]) end)

      assert error.message =~ "authored-slug"
      assert error.message =~ "completely-different-words-here"
    end

    test "a duplicate referencing a missing original fails naming the operator's fix" do
      assert :ok == Seeds.seed_admin!()

      entry = %{
        slug: "dupe-entry",
        title: "Dupe entry",
        description: "x",
        status: :duplicate,
        duplicate_of: "missing-original-slug",
        votes: 0,
        comments: [],
        age_days: 1,
        status_age_days: 0
      }

      error = assert_raise(RuntimeError, fn -> Seeds.seed_feedback!([entry]) end)

      assert error.message =~ "missing-original-slug"
      assert error.message =~ "list the original entry before the duplicate"
    end
  end

  describe "idempotency" do
    test "re-seeding produces no duplicates and never converges admin edits" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      # An admin's edit is data, not drift — the seed must leave it.
      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)

      post =
        Post
        |> Ash.Query.filter(slug == "suspend-an-instance-from-the-cli")
        |> Ash.read_one!(authorize?: false)

      Post.update!(post, %{title: "Renamed by an admin"}, actor: admin, authorize?: false)

      assert :ok == Seeds.seed_feedback!()

      count =
        Post
        |> Ash.Query.filter(slug == "suspend-an-instance-from-the-cli")
        |> Ash.count!(authorize?: false)

      assert count == 1

      renamed =
        Post
        |> Ash.Query.filter(slug == "suspend-an-instance-from-the-cli")
        |> Ash.read_one!(authorize?: false)

      assert renamed.title == "Renamed by an admin"
    end
  end

  describe "demo tagging (T10)" do
    test "the shipped entries carry their tags — a post about Kavita carries the kavita tag" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      assert tags_on!("kavita-continue-reading-sync-across-devices") == ["kavita"]
      assert tags_on!("add-immich-to-the-app-catalog") == ["app-request"]
      assert tags_on!("terraform-provider-for-instance-management") == ["platform"]
      assert tags_on!("show-cost-estimates-in-the-deploy-wizard") == ["platform"]

      # The rest of the shipped set ships untagged (not every post needs
      # a chip).
      assert tags_on!("s3-backed-offsite-backup-exports") == []
      assert tags_on!("alert-on-failing-health-checks") == []
      assert tags_on!("cheaper-storage-for-backup-archives") == []
      assert tags_on!("bring-back-weekly-usage-emails") == []
    end

    test "re-seeding does not duplicate the pairings" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      first =
        PostTag
        |> Ash.read!(authorize?: false)
        |> Enum.count()

      seed_feedback_with_vocabulary!()

      after_second =
        PostTag
        |> Ash.read!(authorize?: false)
        |> Enum.count()

      assert after_second == first
    end

    test "an entry referencing an unknown tag fails naming the operator's fix" do
      assert :ok == Seeds.seed_admin!()

      entry = %{
        slug: "tagged-entry",
        title: "Tagged entry",
        description: "x",
        status: :open,
        votes: 0,
        comments: [],
        age_days: 1,
        status_age_days: 0,
        tags: ["no-such-tag"]
      }

      error = assert_raise(RuntimeError, fn -> Seeds.seed_feedback!([entry]) end)

      assert error.message =~ "no-such-tag"
      assert error.message =~ "seed_tags!/0 must run first"
    end
  end

  describe "counter convergence (#471)" do
    test "converges counters that drifted from their rows" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      # The pre-#471 posture: counters stamped with no rows behind them
      # (the drift staging shipped with). The seed owns its slugs, so a
      # re-run heals them back to the rows' truth.
      post =
        Post
        |> Ash.Query.filter(slug == "terraform-provider-for-instance-management")
        |> Ash.read_one!(authorize?: false)

      FeedbackFixtures.set_counters!(post, 999, 999)

      assert :ok == Seeds.seed_feedback!()

      healed =
        Post
        |> Ash.Query.filter(slug == "terraform-provider-for-instance-management")
        |> Ash.read_one!(authorize?: false)

      assert healed.vote_count == vote_rows_for!(healed.id)
      assert healed.comment_count == comment_rows_for!(healed.id)
    end

    test "re-seeding mints no duplicate activity" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      post =
        Post
        |> Ash.Query.filter(slug == "terraform-provider-for-instance-management")
        |> Ash.read_one!(authorize?: false)

      first_votes = vote_rows_for!(post.id)
      first_comments = comment_rows_for!(post.id)

      assert :ok == Seeds.seed_feedback!()

      assert vote_rows_for!(post.id) == first_votes
      assert comment_rows_for!(post.id) == first_comments

      reseeded =
        Post
        |> Ash.Query.filter(slug == "terraform-provider-for-instance-management")
        |> Ash.read_one!(authorize?: false)

      assert reseeded.vote_count == first_votes
      assert reseeded.comment_count == first_comments
    end

    test "an entry naming more votes than the demo pool fails loudly" do
      assert :ok == Seeds.seed_admin!()

      entry = %{
        slug: "over-pooled-entry",
        title: "Over pooled entry",
        description: "x",
        status: :open,
        votes: 999,
        comments: [],
        age_days: 1,
        status_age_days: 0
      }

      error = assert_raise(RuntimeError, fn -> Seeds.seed_feedback!([entry]) end)

      assert error.message =~ "demo voter pool"
      assert error.message =~ "one vote per org per post"
    end

    test "demo rows never render as just-now on a backdated board" do
      assert :ok == Seeds.seed_admin!()
      seed_feedback_with_vocabulary!()

      post =
        Post
        |> Ash.Query.filter(slug == "terraform-provider-for-instance-management")
        |> Ash.read_one!(authorize?: false)

      # A vote on a 120-day-old post must not stamp "now": both reads
      # the board's renders depend on stay in the past.
      assert DateTime.compare(post.created_at, DateTime.utc_now()) == :lt

      Vote
      |> Ash.Query.filter(post_id == ^post.id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(fn vote ->
        assert DateTime.compare(vote.created_at, DateTime.utc_now()) == :lt
      end)
    end
  end
end
