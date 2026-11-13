defmodule FluxVale.Catalog.AppIconPathTest do
  @moduledoc """
  The action path for `App.icon_url` (#718): the `App.CastIconPath`
  change rides `App.create!` and `App.update!`, so seeds, admin, and
  the API all hit the one gate. The type's own unit tests live in
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

  test "creates an app from string-key params" do
    app = string_key_app!("/images/catalog/forgejo/icon.svg")

    assert App.get_by_slug!(app.slug, authorize?: false).icon_url ==
             "/images/catalog/forgejo/icon.svg"
  end

  test "rejects a hotlinked icon_url at create" do
    assert_raise Ash.Error.Invalid, fn ->
      app!(%{icon_url: "https://example.com/icon.png"})
    end
  end

  test "rejects a hotlinked icon_url from string-key params" do
    assert_raise Ash.Error.Invalid, fn ->
      string_key_app!("https://example.com/icon.png")
    end
  end

  test "rejects a whitespace-padded icon_url at create" do
    assert_raise Ash.Error.Invalid, fn ->
      app!(%{icon_url: " /images/catalog/forgejo/icon.svg"})
    end
  end

  test "rejects a javascript: icon_url from string-key params at create" do
    assert_raise Ash.Error.Invalid, fn ->
      string_key_app!("javascript:alert(1)")
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

  test "normalizes an empty icon_url to nil at create (atom-key params)" do
    app = app!(%{icon_url: ""})

    assert app.icon_url == nil
  end

  test "normalizes an empty icon_url to nil at create (string-key params)" do
    app = string_key_app!("")

    assert app.icon_url == nil
  end

  test "clears an icon_url supplied as an empty string (the AshAdmin blank field)" do
    app = app!(%{icon_url: "/images/catalog/forgejo/icon.svg"})

    cleared = App.update!(app, %{"icon_url" => ""}, authorize?: false)

    assert cleared.icon_url == nil
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

  defp string_key_app!(icon_url) do
    n = System.unique_integer([:positive])

    category =
      Category.create!(
        %{name: "Icon Tools #{n}", slug: "icon-tools-#{n}", description: "Icon tests"},
        authorize?: false
      )

    App.create!(
      %{
        "name" => "String Key App #{n}",
        "slug" => "string-key-app-#{n}",
        "tagline" => "Icon tests",
        "category_id" => category.id,
        "icon_url" => icon_url
      },
      authorize?: false
    )
  end
end
