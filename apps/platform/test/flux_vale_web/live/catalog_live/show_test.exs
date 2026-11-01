defmodule FluxValeWeb.CatalogLive.ShowTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    {_user, conn} = SessionHelpers.user_with_session(conn)
    {:ok, conn: conn}
  end

  test "shows the app, its category, versions, and the deploy entry", %{conn: conn} do
    version =
      InstanceFixtures.app_version!(
        published_at: DateTime.utc_now(),
        release_notes: "First FluxVale catalog release."
      )

    app = Ash.load!(version, [app: :category], authorize?: false).app

    linked_app =
      App.update!(
        app,
        %{
          source_url: "https://example.com/src",
          docs_url: "https://example.com/docs",
          icon_url: "https://example.com/forgejo.png"
        },
        authorize?: false
      )

    {:ok, view, html} = live(conn, ~p"/apps/#{linked_app.slug}")

    assert has_element?(view, "h1", app.name)
    # The band tile renders the app icon (#277 icon-in-tile).
    assert has_element?(view, "img[src='https://example.com/forgejo.png']")
    # The category is the band's mono eyebrow (S7 — was a badge).
    assert has_element?(view, "p.eyebrow", app.category.name)
    assert has_element?(view, "#version-#{version.id}", "v#{version.version}")
    assert has_element?(view, "#deploy-#{version.id}")

    assert has_element?(view, "#deploy-#{version.id}[href='/apps/#{linked_app.slug}/deploy']")
    assert has_element?(view, "a[href='https://example.com/src']", "Source")
    assert has_element?(view, "a[href='https://example.com/docs']", "Docs")

    assert has_element?(
             view,
             "[data-testid='price-#{version.version}']",
             "$1.00/mo · billed hourly"
           )

    assert html =~ "First FluxVale catalog release."
    assert html =~ "Published"
  end

  test "a version without a recommended size shows no price (pre-#125 row)", %{conn: conn} do
    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, :app, authorize?: false).app

    # States actions can't produce: the pre-#125 shape — nil size.
    Ash.Seed.seed!(FluxVale.Catalog.AppVersion, %{
      version: "0.9.0",
      image: "test/image:0.9",
      port: 3000,
      app_id: app.id
    })

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}")

    assert has_element?(view, "[data-testid='price-#{version.version}']")

    refute has_element?(view, "[data-testid='price-0.9.0']")
  end

  test "unknown slug redirects back to the catalog with a flash", %{conn: conn} do
    case live(conn, ~p"/apps/nope") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end

  # An app can exist before its first version — the band Deploy would
  # open a stepper with nothing to pick (#341 review).
  test "an app with no versions hides the band Deploy", %{conn: conn} do
    n = System.unique_integer()

    category =
      Category.create!(
        %{
          name: "Empty #{n}",
          slug: "empty-#{n}",
          description: "Test category #{n} — covers the band's category line."
        },
        authorize?: false
      )

    app =
      App.create!(
        %{name: "Bare #{n}", slug: "bare-#{n}", category_id: category.id},
        authorize?: false
      )

    {:ok, view, html} = live(conn, ~p"/apps/bare-#{n}")

    assert has_element?(view, "h1", "Bare #{n}")
    # The category description lands in the band under the eyebrow
    # (hostile-341 F4) — the field stays readable by the authed app.
    assert has_element?(view, "p", "Test category #{n} — covers the band's category line.")
    # The gate's companion (#341 hostile F7): the Versions heading isn't
    # a dead end — the empty state carries the next step's absence.
    assert html =~ "No versions published yet."
    refute has_element?(view, "a[href='/apps/bare-#{n}/deploy']")
  end

  # #190: the catalog-declared file-access flag surfaces as a badge —
  # the deploy-time surface for "this app's instances carry WebDAV".
  test "a file-access app shows the badge; others don't", %{conn: conn} do
    version = InstanceFixtures.app_version!(file_access: true)
    app = Ash.load!(version, :app, authorize?: false).app

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}")

    assert has_element?(view, "[data-testid='file-access-badge']", "File access")

    plain = InstanceFixtures.app_version!()
    plain_app = Ash.load!(plain, :app, authorize?: false).app

    {:ok, plain_view, _html} = live(conn, ~p"/apps/#{plain_app.slug}")

    refute has_element?(plain_view, "[data-testid='file-access-badge']")
  end
end
