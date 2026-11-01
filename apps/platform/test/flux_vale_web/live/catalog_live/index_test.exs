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

    # The icon-bearing sibling covers the img arm of the icon-in-tile
    # (#277): Forgejo above exercises the letter-fallback arm.
    iconed =
      App.create!(
        %{
          name: "Gitea #{n}",
          slug: "gitea-#{n}",
          tagline: "Git service",
          icon_url: "https://example.com/gitea.png",
          category_id: category.id
        },
        authorize?: false
      )

    {:ok, view, _html} = live(conn, ~p"/apps")

    # The mosaic is one grid: app names are its headings, and the
    # category grouping survives as the mono eyebrow on each card.
    assert has_element?(view, "h2", "Forgejo #{n}")
    assert has_element?(view, "#app-#{app.id}", "Developer Tools #{n}")
    assert has_element?(view, "#app-#{app.id} a, #app-#{app.id}")
    assert has_element?(view, "#app-#{iconed.id} img[src='https://example.com/gitea.png']")
  end

  test "an empty catalog renders the empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/apps")

    assert html =~ "No apps in the catalog yet"
    refute has_element?(view, "#catalog-mosaic a")
  end

  # Categories can exist with zero apps — the mosaic keys its empty
  # state on the flattened app list, not on @categories (#341 review).
  test "categories without apps still render the empty state", %{conn: conn} do
    n = System.unique_integer()
    Category.create!(%{name: "Empty #{n}", slug: "empty-#{n}"}, authorize?: false)

    {:ok, view, html} = live(conn, ~p"/apps")

    assert html =~ "No apps in the catalog yet"
    refute has_element?(view, "#catalog-mosaic a")
  end
end
