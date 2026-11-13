defmodule FluxVale.Catalog.AppIconPathTest do
  @moduledoc """
  The action path for `App.icon_url` (#718): the typed attribute rides
  `App.create!` and `App.update!`, so seeds, admin, and the API all hit
  the one gate. The type's own unit tests live in
  `types/icon_path_test.exs`.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category

  test "creates an app with a vendored icon_url" do
    app = app!(%{icon_url: "/images/catalog/forgejo/icon.svg"})

    assert App.get_by_slug!(app.slug, authorize?: false).icon_url ==
             "/images/catalog/forgejo/icon.svg"
  end

  test "rejects a hotlinked icon_url at create" do
    assert_raise Ash.Error.Invalid, fn ->
      app!(%{icon_url: "https://example.com/icon.png"})
    end
  end

  test "rejects a javascript: icon_url at update (the :update accept list runs the type)" do
    app = app!(%{icon_url: "/images/catalog/forgejo/icon.svg"})

    assert_raise Ash.Error.Invalid, fn ->
      App.update!(app, %{icon_url: "javascript:alert(1)"}, authorize?: false)
    end
  end

  test "rejects a path outside priv/static at update" do
    app = app!(%{icon_url: "/images/catalog/forgejo/icon.svg"})

    assert_raise Ash.Error.Invalid, fn ->
      App.update!(app, %{icon_url: "/images/elsewhere/icon.svg"}, authorize?: false)
    end
  end

  test "accepts a vendored icon_url at update" do
    app = app!(%{icon_url: "/images/catalog/forgejo/icon.svg"})

    updated = App.update!(app, %{icon_url: "/images/catalog/vikunja/icon.png"}, authorize?: false)

    assert updated.icon_url == "/images/catalog/vikunja/icon.png"
  end

  defp app!(attrs) do
    n = System.unique_integer([:positive])

    category =
      Category.create!(
        %{name: "Icon Tools #{n}", slug: "icon-tools-#{n}", description: "Icon tests"},
        authorize?: false
      )

    attrs
    |> Map.merge(%{
      name: "Icon App #{n}",
      slug: "icon-app-#{n}",
      tagline: "Icon tests",
      category_id: category.id
    })
    |> App.create!(authorize?: false)
  end
end
