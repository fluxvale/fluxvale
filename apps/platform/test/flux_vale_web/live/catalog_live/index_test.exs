defmodule FluxValeWeb.CatalogLive.IndexTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.PricingFixtures
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

  # #398: the mosaic cards carry the ladder floor — the public index's
  # number, computed at mount. Expectation from a Size read, never a
  # literal, and a fixture reprice moves the card.
  test "cards carry the computed from-price floor, following reprices", %{conn: conn} do
    n = System.unique_integer()

    category =
      Category.create!(%{name: "Developer Tools #{n}", slug: "tools-#{n}"}, authorize?: false)

    app =
      App.create!(
        %{name: "Forgejo #{n}", slug: "forgejo-#{n}", category_id: category.id},
        authorize?: false
      )

    PricingFixtures.size!(monthly_cents: 701)
    cheapest = PricingFixtures.size!(monthly_cents: 233)

    {:ok, view, _html} = live(conn, ~p"/apps")

    assert has_element?(
             view,
             "#app-#{app.id} [data-testid='from-price']",
             "from #{Pricing.format_monthly_rate(233)}"
           )

    Size.update!(cheapest, %{monthly_cents: 99}, authorize?: false)

    # Fresh mount — the floor is computed per mount, so the card moves
    # and the stale number is gone.
    {:ok, repriced_view, _html} = live(conn, ~p"/apps")

    assert has_element?(
             repriced_view,
             "#app-#{app.id} [data-testid='from-price']",
             "from #{Pricing.format_monthly_rate(99)}"
           )

    refute has_element?(
             repriced_view,
             "#app-#{app.id} [data-testid='from-price']",
             "from #{Pricing.format_monthly_rate(233)}"
           )
  end

  # The empty-table branch mirrors the controller: nil hides the line,
  # never a crash.
  test "cards hide the from-price line on an unseeded table", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/apps")

    refute has_element?(view, "[data-testid='from-price']")
  end

  # The gate is a nil-check, not a truthy one: monthly_cents allows 0,
  # and a $0 floor is still a floor.
  test "a zero-priced floor still renders the from-price line", %{conn: conn} do
    n = System.unique_integer()

    category =
      Category.create!(%{name: "Developer Tools #{n}", slug: "tools-#{n}"}, authorize?: false)

    app =
      App.create!(
        %{name: "Forgejo #{n}", slug: "forgejo-#{n}", category_id: category.id},
        authorize?: false
      )

    PricingFixtures.size!(monthly_cents: 0)

    {:ok, view, _html} = live(conn, ~p"/apps")

    assert has_element?(
             view,
             "#app-#{app.id} [data-testid='from-price']",
             "from #{Pricing.format_monthly_rate(0)}"
           )
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
