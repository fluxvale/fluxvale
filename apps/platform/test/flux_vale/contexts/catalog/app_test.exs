defmodule FluxVale.Catalog.AppTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Identity.User

  defp category do
    Category.create!(%{name: "Media #{System.unique_integer()}", slug: "media"},
      authorize?: false
    )
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  describe "create/2" do
    test "creates linked to a category" do
      category = category()

      assert {:ok, app} =
               App.create(
                 %{
                   name: "Kavita",
                   slug: "kavita",
                   tagline: "Reading server",
                   category_id: category.id
                 },
                 authorize?: false
               )

      assert app.category_id == category.id
      assert app.tagline == "Reading server"
    end

    test "requires a category (belongs_to allow_nil? false)" do
      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Orphan", slug: "orphan"}, authorize?: false)
    end

    test "rejects non-URL-shaped slugs and enforces unique slug/name" do
      category = category()

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Bad", slug: "Bad Slug", category_id: category.id},
                 authorize?: false
               )

      App.create!(%{name: "Kavita", slug: "kavita", category_id: category.id}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Other", slug: "kavita", category_id: category.id},
                 authorize?: false
               )

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Kavita", slug: "other", category_id: category.id},
                 authorize?: false
               )
    end

    test "bounds tagline to 140 chars" do
      category = category()

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(
                 %{
                   name: "Long",
                   slug: "long",
                   category_id: category.id,
                   tagline: String.duplicate("x", 141)
                 },
                 authorize?: false
               )
    end
  end

  describe "get_by_slug/1" do
    test "fetches by slug or errors" do
      category = category()

      created =
        App.create!(%{name: "Kavita", slug: "kavita", category_id: category.id},
          authorize?: false
        )

      assert {:ok, fetched} = App.get_by_slug("kavita", authorize?: false)
      assert fetched.id == created.id

      assert {:error, _not_found} = App.get_by_slug("nope", authorize?: false)
    end
  end

  describe "policy" do
    test "any signed-in actor reads; non-admins cannot mutate" do
      category = category()

      app =
        App.create!(%{name: "Kavita", slug: "kavita", category_id: category.id},
          authorize?: false
        )

      regular = regular_user()

      assert {:ok, [_row]} = Ash.read(App, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(app, %{tagline: "no"}, actor: regular, authorize?: true)
    end
  end
end
