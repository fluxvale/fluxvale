defmodule FluxValeWeb.CatalogLive.ShowTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
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
        %{source_url: "https://example.com/src", docs_url: "https://example.com/docs"},
        authorize?: false
      )

    {:ok, view, html} = live(conn, ~p"/apps/#{linked_app.slug}")

    assert has_element?(view, "h1", app.name)
    assert has_element?(view, ".badge", app.category.name)
    assert has_element?(view, "#version-#{version.id}", "v#{version.version}")
    assert has_element?(view, "#deploy-#{version.id}")

    assert has_element?(view, "#deploy-#{version.id}[href='/apps/#{linked_app.slug}/deploy']")
    assert has_element?(view, "a[href='https://example.com/src']", "Source")
    assert has_element?(view, "a[href='https://example.com/docs']", "Docs")
    assert html =~ "First FluxVale catalog release."
    assert html =~ "Published"
  end

  test "unknown slug redirects back to the catalog with a flash", %{conn: conn} do
    case live(conn, ~p"/apps/nope") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end
end
