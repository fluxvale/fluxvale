defmodule FluxValeWeb.CatalogControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  # Catalog fixture, mirroring the CatalogLive tests: actions with
  # `authorize?: false` (test preconditions ride the bootstrap posture).
  defp catalog_app!(attrs \\ %{}) do
    n = System.unique_integer()

    category =
      Category.create!(
        %{name: "Developer Tools #{n}", slug: "tools-#{n}", description: "Build things"},
        authorize?: false
      )

    base_attrs = %{
      name: "Forgejo #{n}",
      slug: "forgejo-#{n}",
      tagline: "Painless self-hosted Git",
      category_id: category.id
    }

    overrides = Map.new(attrs)

    base_attrs
    |> Map.merge(overrides)
    |> App.create!(authorize?: false)
  end

  describe "GET /catalog" do
    test "renders category-grouped app cards for anonymous visitors", %{conn: conn} do
      # icon_url exercises the SSR tile's img arm — the LiveView twin
      # covers it, this file didn't (#277 T4 review).
      app = catalog_app!(icon_url: "https://example.com/icon.png")

      conn = get(conn, ~p"/catalog")
      html = html_response(conn, 200)

      assert html =~ "App catalog"
      assert html =~ app.name
      assert html =~ app.tagline
      assert html =~ ~s(href="/catalog/#{app.slug}")
      assert html =~ ~s(src="https://example.com/icon.png")
    end

    test "renders the empty state", %{conn: conn} do
      conn = get(conn, ~p"/catalog")

      assert html_response(conn, 200) =~ "No apps in the catalog yet"
    end

    test "signed-in visitors see the same page — the read is public, not gated", %{conn: conn} do
      {user, signed_conn} = SessionHelpers.user_with_session(conn)
      app = catalog_app!()

      result = get(signed_conn, ~p"/catalog")

      # Same page plus the display-only chrome: email + sign-out.
      html = html_response(result, 200)
      assert html =~ app.name
      assert html =~ to_string(user.email)
    end

    test "a non-canonical host renders the noindex meta + header", %{conn: conn} do
      conn = get(%{conn | host: "staging.fluxvale.com"}, ~p"/catalog")

      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert html_response(conn, 200) =~ ~s(name="robots" content="noindex, nofollow")
    end

    test "meta: branded title, description, canonical, and OG/Twitter tags", %{conn: conn} do
      catalog_app!()

      html =
        conn
        |> get(~p"/catalog")
        |> html_response(200)

      # live_title renders <title data-default="FluxVale">…</title> — the
      # content is the full branded string the controller assigned.
      assert [_match, title] = Regex.run(~r{<title[^>]*>(.*)</title>}s, html)
      assert title == "App catalog · FluxVale"
      refute title =~ "Phoenix"
      # phx-r sits on rendered elements — assert on attribute pairs, not
      # the full tag.
      assert html =~ ~s(name="description" content="Managed hosting for open source apps")
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/catalog")
      assert html =~ ~s(property="og:title" content="App catalog · FluxVale")
      assert html =~ "https://fluxvale.com/images/og-default.png"
      assert html =~ ~s(name="twitter:card" content="summary_large_image")
    end

    test "the canonical host carries no noindex marker", %{conn: conn} do
      conn = get(%{conn | host: "fluxvale.com"}, ~p"/catalog")
      html = html_response(conn, 200)

      assert get_resp_header(conn, "x-robots-tag") == []
      refute html =~ "noindex"
    end
  end

  describe "GET /catalog/:slug" do
    test "renders the app page: header, description, versions, price, deploy CTA", %{conn: conn} do
      version =
        InstanceFixtures.app_version!(
          published_at: DateTime.utc_now(),
          release_notes: "First FluxVale catalog release."
        )

      app_row = Ash.load!(version, [app: :category], authorize?: false).app
      category_name = app_row.category.name

      app =
        App.update!(
          app_row,
          %{
            icon_url: "https://example.com/icon.png",
            source_url: "https://example.com/src",
            docs_url: "https://example.com/docs"
          },
          authorize?: false
        )

      conn = get(conn, ~p"/catalog/#{app.slug}")
      html = html_response(conn, 200)

      assert html =~ app.name
      assert html =~ app.tagline
      assert html =~ category_name
      assert html =~ ~s(src="https://example.com/icon.png")
      assert html =~ ~s(href="https://example.com/src")
      assert html =~ ~s(href="https://example.com/docs")
      assert html =~ ~s(href="/apps/#{app.slug}/deploy")
      assert html =~ ~s(data-testid="price-#{version.version}")
      assert html =~ "$1.00/mo · billed hourly"
      assert html =~ "Published"
      assert html =~ "First FluxVale catalog release."
    end

    test "meta: branded title, description, canonical, and the JSON-LD payload", %{conn: conn} do
      app = catalog_app!()

      html =
        conn
        |> get(~p"/catalog/#{app.slug}")
        |> html_response(200)

      assert [_match, title] = Regex.run(~r{<title[^>]*>(.*)</title>}s, html)
      assert title == "#{app.name} · FluxVale"
      refute title =~ "Phoenix"
      assert html =~ ~s(name="description" content="#{app.tagline}")
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/catalog/#{app.slug}")

      assert [_match, encoded] = Regex.run(~r/id="ld-json-app">(.*?)<\/script>/s, html)
      data = Jason.decode!(encoded)

      assert data["@context"] == "https://schema.org"
      assert data["@type"] == "SoftwareApplication"
      assert data["name"] == app.name
      assert data["description"] == app.tagline
      assert data["url"] == "https://fluxvale.com/catalog/#{app.slug}"
      assert data["operatingSystem"] == "Web"
    end

    test "an unknown slug is a real 404 — crawlers get the truth", %{conn: conn} do
      # The endpoint rescues NoRouteError and renders the error view —
      # the crawler-visible fact is the 404 status itself.
      conn = get(conn, ~p"/catalog/nope")

      assert conn.status == 404
      assert html_response(conn, 404) =~ "Not Found"
    end
  end
end
