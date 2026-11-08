defmodule FluxVale.Catalog.CategoryTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Identity.User

  defp admin do
    case User.get_by_email("admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
    end
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  describe "create/2" do
    test "creates with the accepted fields" do
      assert {:ok, category} =
               Category.create(
                 %{name: "Databases", slug: "databases", description: "Data stores"},
                 authorize?: false
               )

      assert category.slug == "databases"
      assert category.icon == nil
    end

    test "rejects non-URL-shaped slugs; accepts single-character slugs" do
      assert {:error, %Ash.Error.Invalid{}} =
               Category.create(%{name: "Bad", slug: "Not A Slug"}, authorize?: false)

      assert {:ok, single} = Category.create(%{name: "Single", slug: "a"}, authorize?: false)
      assert single.slug == "a"
    end

    test "enforces unique slug and unique name" do
      Category.create!(%{name: "Media", slug: "media"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Category.create(%{name: "Other", slug: "media"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Category.create(%{name: "Media", slug: "other"}, authorize?: false)
    end

    # #611 (D5): the audience line every app page in the category
    # renders as its hero's "who it suits" paragraph.
    test "accepts an audience line up to 180 chars, in create and update" do
      line = "A fit for teams that want their own source control without running the servers."

      assert {:ok, category} =
               Category.create(
                 %{name: "Developer Tools", slug: "devtools", audience: line},
                 authorize?: false
               )

      assert category.audience == line

      updated =
        Category.update!(category, %{audience: "A fit for someone else."}, authorize?: false)

      assert updated.audience == "A fit for someone else."
    end

    test "rejects an audience line over 180 chars" do
      assert {:error, %Ash.Error.Invalid{}} =
               Category.create(
                 %{name: "Long", slug: "long-audience", audience: String.duplicate("a", 181)},
                 authorize?: false
               )
    end

    # D10: audience is curated copy — em dashes and semicolons reject.
    test "rejects an audience line with an em dash or semicolon" do
      for line <- ["Teams — plain sentences only.", "Teams; no semicolons either."] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Category.create(%{name: "Copy", slug: "copy-audience", audience: line},
                   authorize?: false
                 )
      end
    end
  end

  describe "get_by_slug/1" do
    test "fetches by slug or errors" do
      created = Category.create!(%{name: "Media", slug: "media"}, authorize?: false)

      assert {:ok, fetched} = Category.get_by_slug("media", authorize?: false)
      assert fetched.id == created.id

      assert {:error, _not_found} = Category.get_by_slug("nope", authorize?: false)
    end
  end

  describe "policy (ADR-0027: mutations ride ActorIsPlatformAdmin)" do
    setup do
      %{admin: admin(), regular: regular_user()}
    end

    test "public read — anonymous browse included (#164); mutations stay admin-gated", %{
      regular: regular
    } do
      Category.create!(%{name: "Media", slug: "media"}, authorize?: false)

      assert {:ok, [_row]} = Ash.read(Category, actor: regular, authorize?: true)

      assert {:ok, [_row]} = Ash.read(Category, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Category.create(%{name: "Blocked", slug: "blocked"}, authorize?: true)
    end

    test "non-admins cannot mutate; admins create and update — the AshAdmin paths",
         %{admin: admin, regular: regular} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Category.create(%{name: "Blocked", slug: "blocked"},
                 actor: regular,
                 authorize?: true
               )

      category = Category.create!(%{name: "Media", slug: "media"}, authorize?: false)

      assert {:ok, updated} =
               Ash.update(category, %{description: "changed"}, actor: admin, authorize?: true)

      assert updated.description == "changed"

      assert :ok = Ash.destroy(updated, actor: admin, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(category, %{description: "no"}, actor: regular, authorize?: true)
    end
  end

  describe "destroy with dependents" do
    test "fails on the FK — apps reference categories, no cascade" do
      category = Category.create!(%{name: "Media", slug: "media"}, authorize?: false)

      App.create!(
        %{name: "Kavita", slug: "kavita", category_id: category.id},
        # Test precondition: the FK behavior is the subject, not policy.
        authorize?: false
      )

      assert {:error, %Ash.Error.Invalid{}} = Ash.destroy(category, authorize?: false)

      assert {:ok, [_still_there]} = Ash.read(App, authorize?: false)
    end
  end
end
