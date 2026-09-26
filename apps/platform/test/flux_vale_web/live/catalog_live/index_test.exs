defmodule FluxValeWeb.CatalogLive.IndexTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    {_user, conn} = SessionHelpers.user_with_session(conn)
    {:ok, conn: conn}
  end

  test "lists categories with their apps", %{conn: conn} do
    n = System.unique_integer()

    category =
      Category.create!(%{name: "Developer Tools #{n}", slug: "tools-#{n}"}, authorize?: false)

    app =
      App.create!(
        %{
          name: "Forgejo #{n}",
          slug: "forgejo-#{n}",
          tagline: "Git forge",
          category_id: category.id
        },
        authorize?: false
      )

    {:ok, view, _html} = live(conn, ~p"/apps")

    assert has_element?(view, "h2", "Developer Tools #{n}")
    assert has_element?(view, "#app-#{app.id}", "Forgejo #{n}")
    assert has_element?(view, "#app-#{app.id} a, #app-#{app.id}")
  end

  test "an empty catalog renders the empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/apps")

    assert html =~ "No apps in the catalog yet"
    refute has_element?(view, "section")
  end
end
