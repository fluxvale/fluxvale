defmodule FluxVale.Seeds.FeedbackSeedTest do
  @moduledoc """
  The feedback seed flow (`FluxVale.Seeds.seed_feedback!/0`, #412 T4)
  against a sandboxed DB — the shipped starter entries, statuses moved
  through the real action, counters and display timestamps riding forced
  attribute changes, and get-or-create idempotency.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Feedback.Post
  alias FluxVale.Identity.User
  alias FluxVale.Seeds

  require Ash.Query

  describe "seed_feedback!/0 (shipped entries)" do
    test "seeds starter posts covering every status" do
      assert :ok == Seeds.seed_admin!()
      assert :ok == Seeds.seed_feedback!()

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

      # The fabricated counters (no minting slice exists yet).
      assert by_slug.("terraform-provider-for-instance-management").vote_count == 128
      assert by_slug.("terraform-provider-for-instance-management").comment_count == 21
      assert dup.vote_count == 0
    end

    test "backdates display timestamps; open posts stay unmoved" do
      assert :ok == Seeds.seed_admin!()
      assert :ok == Seeds.seed_feedback!()

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

  describe "idempotency" do
    test "re-seeding produces no duplicates and never converges admin edits" do
      assert :ok == Seeds.seed_admin!()
      assert :ok == Seeds.seed_feedback!()

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
end
