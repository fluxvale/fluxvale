defmodule FluxVale.TestSupport.FeedbackFixtures do
  @moduledoc """
  Preconditions for the board-surface tests (#412 T4): posts built
  through the resource's actions — creates run `authorize?: false` with
  the admin actor (org + creator derive from it, mirroring seeds); status
  moves run the action under the actor. Counters have no minting slice
  yet, so they ride forced attribute changes (states actions cannot
  produce, the seed posture). Tags (T10) run the admin-gated actions —
  the vocabulary and the tagging are both moderation, the gate is the
  tests' business where it is asserted.
  """

  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Tag
  alias FluxVale.TestSupport.AccountsFixtures

  @doc "A post born open (unless attrs carry overrides)."
  def post!(attrs \\ %{}) do
    defaults = %{
      title: "Fixture post #{System.unique_integer([:positive])}",
      description: "A fixture post"
    }

    Post.create!(Map.merge(defaults, attrs), actor: admin(), authorize?: false)
  end

  @doc "Moves a post's status through the admin-gated action."
  def move_status!(post, status, opts \\ []) do
    args =
      case Keyword.fetch(opts, :duplicate_of) do
        {:ok, original} -> %{status: status, duplicate_of_id: original.id}
        :error -> %{status: status}
      end

    Post.set_status!(post, args, actor: admin())
  end

  @doc "Fabricates the cached counters (no minting slice yet)."
  def set_counters!(post, votes, comments) do
    post
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:vote_count, votes)
    |> Ash.Changeset.force_change_attribute(:comment_count, comments)
    |> Ash.update!(authorize?: false)
  end

  @doc """
  Backdates the status-change stamp to a chosen instant (the roadmap's
  recency ordering + the sitemap lastmod need controlled pasts; no
  action accepts timestamps, the seeds' forced-attribute posture).
  """
  def set_status_changed_at!(post, changed_at) do
    post
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:status_changed_at, changed_at)
    |> Ash.update!(authorize?: false)
  end

  @doc """
  A curated tag (T10). Defaults derive a unique name so suites stay
  independent; the slug derives from it. The create runs `authorize?:
  false` — precondition, mirroring seeds (the gate itself is asserted
  in TagTest).
  """
  def tag!(attrs \\ %{}) do
    defaults = %{name: "Tag #{System.unique_integer([:positive])}"}
    Tag.create!(Map.merge(defaults, attrs), actor: admin(), authorize?: false)
  end

  @doc "Tags a post through the moderation action (admin actor)."
  def tag_post!(post, tags) do
    tag_ids = Enum.map(tags, & &1.id)
    Post.set_tags!(post, %{tag_ids: tag_ids}, actor: admin())
  end

  defp admin, do: AccountsFixtures.platform_admin!()
end
