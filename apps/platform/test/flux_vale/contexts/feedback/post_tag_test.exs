defmodule FluxVale.Feedback.PostTagTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.FeedbackFixtures

  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.PostTag
  alias FluxVale.TestSupport.AccountsFixtures

  describe "policies (tagging is moderation, T10)" do
    test "reads are public — the board loads posts' chips anonymously" do
      tag = tag!()
      post = post!()
      tag_post!(post, [tag])

      assert {:ok, rows} = Ash.read(PostTag)
      assert Enum.any?(rows, &(&1.post_id == post.id and &1.tag_id == tag.id))
    end

    test "a plain user cannot set a post's tags" do
      tag = tag!()
      post = post!()
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Post.set_tags(post, %{tag_ids: [tag.id]}, actor: user)
    end

    test "anonymous cannot set a post's tags" do
      tag = tag!()
      post = post!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Post.set_tags(post, %{tag_ids: [tag.id]}, authorize?: true)
    end

    test "a plain user cannot write the join rows directly" do
      tag = tag!()
      post = post!()
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               PostTag.create(%{post_id: post.id, tag_id: tag.id}, actor: user)
    end

    test "a platform admin sets a post's tags" do
      tag = tag!()
      post = post!()

      assert {:ok, tagged} =
               Post.set_tags(post, %{tag_ids: [tag.id]},
                 actor: AccountsFixtures.platform_admin!()
               )

      assert Enum.map(tagged.tags, & &1.slug) == [tag.slug]
    end
  end

  describe "set_tags semantics" do
    test "the list is the whole truth — replace, not append" do
      platform = tag!(%{name: "Platform", slug: "platform"})
      kavita = tag!(%{name: "Kavita", slug: "kavita"})
      forgejo = tag!(%{name: "Forgejo", slug: "forgejo"})
      post = post!()

      tagged = tag_post!(post, [platform, kavita])

      # The in-memory tags ride the changeset's order, not the load sort —
      # compare as a set (the load order is its own test below).
      slugs =
        tagged.tags
        |> Enum.map(& &1.slug)
        |> Enum.sort()

      assert slugs == ["kavita", "platform"]

      replaced = tag_post!(post, [forgejo])

      assert Enum.map(replaced.tags, & &1.slug) == ["forgejo"]
    end

    test "an empty list removes every tag" do
      platform = tag!(%{name: "Platform", slug: "platform"})
      post = post!()
      tag_post!(post, [platform])

      cleared = tag_post!(post, [])

      assert cleared.tags == []

      assert {:ok, []} = Ash.read(PostTag, authorize?: false)
    end

    test "an unknown tag id fails the write loudly, nothing written" do
      post = post!()

      assert {:error, %Ash.Error.Invalid{}} =
               Post.set_tags(post, %{tag_ids: [Ash.UUID.generate()]},
                 actor: AccountsFixtures.platform_admin!()
               )

      assert {:ok, []} = Ash.read(PostTag, authorize?: false)
    end

    test "a missing tag_ids argument reads as no tags (the default)" do
      post = post!()

      assert {:ok, tagged} =
               Post.set_tags(post, %{}, actor: AccountsFixtures.platform_admin!())

      assert tagged.tags == []
    end

    test "duplicate ids in one call are refused field-scoped, nothing written" do
      # manage_relationship does not dedupe its input: the second
      # identical id collides the join's unique identity and the write
      # answers field-scoped on the pairing, with no rows written. The
      # action is the whole-truth replace, so the caller re-sends the
      # deduped list.
      platform = tag!(%{name: "Platform", slug: "platform"})
      kavita = tag!(%{name: "Kavita", slug: "kavita"})
      post = post!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.set_tags(post, %{tag_ids: [platform.id, kavita.id, platform.id]},
                 actor: AccountsFixtures.platform_admin!()
               )

      assert Enum.any?(
               errors,
               &(&1.field == :post_id and &1.message == "has already been taken")
             )

      assert {:ok, []} = Ash.read(PostTag, authorize?: false)
    end
  end

  describe "join uniqueness" do
    test "a direct duplicate pairing is refused by the identity" do
      tag = tag!()
      post = post!()
      tag_post!(post, [tag])

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               PostTag.create(%{post_id: post.id, tag_id: tag.id}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :post_id and &1.message == "has already been taken")
             )
    end

    test "re-setting the same list does not duplicate the pairings" do
      platform = tag!(%{name: "Platform", slug: "platform"})
      kavita = tag!(%{name: "Kavita", slug: "kavita"})
      post = post!()

      tag_post!(post, [platform, kavita])
      tag_post!(post, [kavita, platform])

      pairings =
        PostTag
        |> Ash.read!(authorize?: false)
        |> Enum.count()

      assert pairings == 2
    end
  end

  describe "deleting a post takes its pairings (cascade)" do
    test "moderation's delete clears the join rows" do
      admin = AccountsFixtures.platform_admin!()
      tag = tag!()
      post = post!()
      tag_post!(post, [tag])

      assert :ok = Ash.destroy(post, actor: admin)

      assert {:ok, []} = Ash.read(PostTag, authorize?: false)
    end
  end

  describe "reads" do
    test "loading a post's tags sorts by name" do
      kavita = tag!(%{name: "Kavita", slug: "kavita"})
      platform = tag!(%{name: "Platform", slug: "platform"})
      post = post!()

      # Tag in the reverse order of the expected display.
      tag_post!(post, [platform, kavita])

      loaded = Ash.load!(post, :tags, actor: nil)

      assert Enum.map(loaded.tags, & &1.slug) == ["kavita", "platform"]
    end
  end
end
