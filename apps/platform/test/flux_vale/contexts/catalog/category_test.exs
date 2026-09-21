defmodule FluxVale.Catalog.CategoryTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

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

    test "rejects non-URL-shaped slugs" do
      assert {:error, %Ash.Error.Invalid{}} =
               Category.create(%{name: "Bad", slug: "Not A Slug"}, authorize?: false)
    end

    test "enforces unique slug and unique name" do
      Category.create!(%{name: "Media", slug: "media"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Category.create(%{name: "Other", slug: "media"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Category.create(%{name: "Media", slug: "other"}, authorize?: false)
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

    test "any signed-in actor reads; anonymous is denied", %{regular: regular} do
      Category.create!(%{name: "Media", slug: "media"}, authorize?: false)

      assert {:ok, [_row]} = Ash.read(Category, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Category, authorize?: true)
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
end
