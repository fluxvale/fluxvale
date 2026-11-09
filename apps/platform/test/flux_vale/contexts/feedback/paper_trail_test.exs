defmodule FluxVale.Feedback.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Feedback (#645, the plan's A2-S2 slice):
  # moderation writes attribute to the admin, member writes attribute
  # to the member. Mirrors the Ops suite (the A2-S1 exemplar):
  # version-row reads that assert STORAGE run authorize?: false; the
  # D7 version-read policy is pinned there.

  use FluxVale.DataCase, async: true

  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  defp versions!(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # System-shaped precondition (SetActorDefaults' documented nil-author
  # bootstrap): a named org, no actor. The author notification then has
  # no address to resolve, so the moderation write below stays a pure
  # storage assertion.
  defp post!(org) do
    Post
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: "Trail post #{System.unique_integer([:positive])}",
        description: "trail proof",
        organization_id: org.id
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "attribution (who made the write)" do
    test "a set_status moderation write attributes to the admin actor" do
      admin = AccountsFixtures.admin!()
      org = AccountsFixtures.owned_org!(AccountsFixtures.user!())
      post = post!(org)

      post
      |> Ash.Changeset.for_update(:set_status, %{status: :planned}, actor: admin)
      |> Ash.update!()

      [_create_version, status_version] = versions!(Post.Version, post.id)

      assert status_version.version_action_type == :update
      assert status_version.version_action_name == :set_status
      assert status_version.changes["status"] == "planned"
      assert status_version.version_action_inputs == %{"status" => "planned"}
      assert status_version.user_id == admin.id
      assert status_version.actor_label == admin.username
    end

    test "a member's comment create attributes to that member" do
      member = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(member)
      post = post!(org)

      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{post_id: post.id, body: "a member comment"},
          actor: member
        )
        |> Ash.create!()

      [version] = versions!(Comment.Version, comment.id)

      assert version.version_action_type == :create
      assert version.user_id == member.id
      assert version.actor_label == member.username
      assert version.changes["body"] == "a member comment"
      assert version.version_action_inputs["body"] == "a member comment"
    end
  end
end
