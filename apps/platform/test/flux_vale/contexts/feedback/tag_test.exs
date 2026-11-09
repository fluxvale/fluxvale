defmodule FluxVale.Feedback.TagTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.FeedbackFixtures

  alias FluxVale.Feedback.PostTag
  alias FluxVale.Feedback.Tag
  alias FluxVale.TestSupport.AccountsFixtures

  describe "policies (T10: curated vocabulary)" do
    test "reads are public — anonymous reads the rows" do
      n = System.unique_integer([:positive])
      tag = Tag.create!(%{name: "Platform #{n}", slug: "platform-#{n}"}, authorize?: false)

      assert {:ok, rows} = Ash.read(Tag)
      assert Enum.any?(rows, &(&1.id == tag.id))
    end

    test "anonymous create is Forbidden" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Tag.create(%{name: "Platform"}, authorize?: true)
    end

    test "a plain user create is Forbidden" do
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Tag.create(%{name: "Platform"}, actor: user)
    end

    test "a plain user update is Forbidden" do
      n = System.unique_integer([:positive])
      tag = Tag.create!(%{name: "Platform #{n}", slug: "platform-#{n}"}, authorize?: false)
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.update(tag, %{name: "Renamed"}, actor: user)
    end

    test "a plain user destroy is Forbidden" do
      n = System.unique_integer([:positive])
      tag = Tag.create!(%{name: "Platform #{n}", slug: "platform-#{n}"}, authorize?: false)
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(tag, actor: user)
    end

    test "a platform admin creates, renames, and removes" do
      admin = AccountsFixtures.platform_admin!()
      n = System.unique_integer([:positive])

      assert {:ok, tag} = Tag.create(%{name: "Platform #{n}"}, actor: admin)
      assert {:ok, renamed} = Ash.update(tag, %{name: "Platform things"}, actor: admin)
      assert renamed.name == "Platform things"
      assert :ok = Ash.destroy(renamed, actor: admin)
    end
  end

  describe "slug derivation (authored or derived, post-slug rules)" do
    test "an absent slug derives from the name" do
      n = System.unique_integer([:positive])
      slug = "app-request-#{n}"

      assert %{slug: ^slug} = Tag.create!(%{name: "App request #{n}"}, authorize?: false)
    end

    test "an authored slug wins over the derivation" do
      n = System.unique_integer([:positive])
      slug = "kavita-#{n}"

      assert %{slug: ^slug} =
               Tag.create!(%{name: "Kavita #{n}", slug: slug}, authorize?: false)
    end

    test "a forced slug (the seed's get-or-create shape) is not clobbered" do
      n = System.unique_integer([:positive])
      slug = "app-request-#{n}"

      changeset =
        Tag
        |> Ash.Changeset.for_create(:create, %{name: "App request #{n}"}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:slug, slug)

      assert %{slug: ^slug} = Ash.create!(changeset, authorize?: false)
    end

    test "long names truncate to the 50-char slug budget" do
      name = "An extremely long tag name that keeps going past the fifty character limit"

      assert tag = Tag.create!(%{name: name}, authorize?: false)
      assert String.length(tag.slug) <= 50
      assert String.starts_with?(tag.slug, "an-extremely-long-tag-name")
    end

    test "a name that sanitizes to nothing is refused field-scoped" do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Tag.create(%{name: "???"}, authorize?: false)

      assert Enum.any?(errors, &(&1.field == :slug))
    end

    test "slug is immutable after create — renames keep the stem" do
      n = System.unique_integer([:positive])
      slug = "platform-#{n}"
      tag = Tag.create!(%{name: "Platform #{n}", slug: slug}, authorize?: false)
      admin = AccountsFixtures.platform_admin!()

      assert %{slug: ^slug} = Ash.update!(tag, %{name: "Platform requests"}, actor: admin)
    end

    test "a duplicate slug is refused by the identity" do
      n = System.unique_integer([:positive])
      Tag.create!(%{name: "Platform #{n}", slug: "platform-#{n}"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Tag.create(%{name: "Platform again", slug: "platform-#{n}"}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :slug and &1.message == "has already been taken")
             )
    end

    test "a slug that breaks the URL shape is refused" do
      assert {:error, %Ash.Error.Invalid{}} =
               Tag.create(%{name: "Spaced", slug: "Not A Slug"}, authorize?: false)
    end

    test "the name keeps a minimum length" do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Tag.create(%{name: "x"}, authorize?: false)

      assert Enum.any?(errors, &(&1.field == :name))
    end
  end

  describe "get_by_slug" do
    test "finds the tag by slug" do
      n = System.unique_integer([:positive])
      slug = "platform-#{n}"
      tag = Tag.create!(%{name: "Platform #{n}", slug: slug}, authorize?: false)

      assert {:ok, fetched} = Tag.get_by_slug(slug, authorize?: false)
      assert fetched.id == tag.id
    end

    test "an unknown slug is not found" do
      assert {:error, _not_found} = Tag.get_by_slug("no-such-tag", authorize?: false)
    end
  end

  describe "deleting a tag takes its pairings" do
    test "the join rows cascade at the DB" do
      admin = AccountsFixtures.platform_admin!()
      n = System.unique_integer([:positive])
      tag = tag!(%{name: "Platform #{n}", slug: "platform-#{n}"})
      post = post!()
      tagged = tag_post!(post, [tag])
      Ash.load!(tagged, :tags, actor: nil)

      assert :ok = Ash.destroy(tag, actor: admin)

      assert {:ok, []} = Ash.read(PostTag, authorize?: false)
    end
  end
end
