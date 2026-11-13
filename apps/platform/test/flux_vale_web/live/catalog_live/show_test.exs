defmodule FluxValeWeb.CatalogLive.ShowTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion.SetSortKey
  alias FluxVale.Catalog.Category
  alias FluxVale.Pricing
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    {_user, conn} = SessionHelpers.user_with_session(conn)
    {:ok, conn: conn}
  end

  # The DOM index of a testid — #611 S6 asserts the plan's section order
  # the same way the public page's controller test does.
  defp index_of(html, marker) do
    case :binary.match(html, marker) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{marker} on the page")
    end
  end

  test "the version list is semver-newest-first and the hero prices the bare release (#700)",
       %{conn: conn} do
    release =
      InstanceFixtures.app_version!(%{version: "3.4.1", monthly_cents: 100})

    bundled =
      InstanceFixtures.app_version!(%{
        app_id: release.app_id,
        version: "3.4.1-bundled",
        # a distinct rate so the hero's pick is asserted, not assumed
        monthly_cents: 295
      })

    older = InstanceFixtures.app_version!(%{app_id: release.app_id, version: "3.4.0"})

    app = Ash.load!(release, :app, authorize?: false).app

    {:ok, view, html} = live(conn, ~p"/apps/#{app.slug}")

    # String order would list "-bundled" above its release; semver
    # puts the pre-release below it, and 3.4.0 last.
    assert index_of(html, "id=\"version-#{release.id}\"") <
             index_of(html, "id=\"version-#{bundled.id}\"")

    assert index_of(html, "id=\"version-#{bundled.id}\"") <
             index_of(html, "id=\"version-#{older.id}\"")

    # newest_version drives the hero's pricing card — the bare
    # release's rate, never the bundled row's.
    assert has_element?(view, "#pricing-card", "$1.00")
    refute has_element?(view, "#pricing-card", "$2.95")
  end

  test "shows the marketing page and the version cards below it", %{conn: conn} do
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
          icon_url: "/images/catalog/forgejo/icon.svg"
        },
        authorize?: false
      )

    {:ok, view, html} = live(conn, ~p"/apps/#{linked_app.slug}")

    # The hero, at parity with the public page (#611 S2): the display
    # H1, the icon-led row, the mono category eyebrow, and the back
    # link targeting the authenticated catalog.
    assert has_element?(view, "h1", "#{linked_app.name} hosting")

    assert has_element?(
             view,
             "[data-testid='app-icon'] img[src='/images/catalog/forgejo/icon.svg']"
           )

    assert has_element?(view, "p.eyebrow", app.category.name)
    # Scoped to the page's own container: the chrome's nav already links
    # /apps, so an unscoped selector would pass without the hero link.
    assert has_element?(view, ".catalog-page a[href='/apps']", "Catalog")
    refute has_element?(view, ".catalog-page a[href='/catalog']")

    # The hero's aside: the pricing card prices the newest version and
    # its CTA is the same stepper entry the version cards use.
    assert has_element?(view, "#pricing-card")

    assert has_element?(
             view,
             "[data-testid='deploy-cta'][href='/apps/#{linked_app.slug}/deploy']"
           )

    # The reader's exits ride the hero's link row.
    assert has_element?(view, "a[href='https://example.com/src']", "Source")
    assert has_element?(view, "a[href='https://example.com/docs']", "Docs")

    # The generated sections (S3) — the curated two self-omit on an
    # unauthored app (S4, plan §5).
    assert has_element?(view, "[data-testid='benefits-section']")
    assert has_element?(view, "[data-testid='faq-section']")
    assert has_element?(view, "[data-testid='similar-section']")
    assert has_element?(view, "[data-testid='cta-section']")

    # The console's own catalog, not the public surface: the browse
    # fallback and the closing CTA's ghost button both stay in /apps.
    assert has_element?(view, "[data-testid='browse-card'][href='/apps']")
    assert has_element?(view, "[data-testid='cta-browse'][href='/apps']")
    refute has_element?(view, "[data-testid='in-action-section']")
    refute has_element?(view, "[data-testid='features-section']")

    # D12: the version cards keep their content, below the marketing
    # page's closing CTA.
    assert has_element?(view, "[data-testid='versions-heading']", "Versions")
    assert has_element?(view, "#version-#{version.id}", "v#{version.version}")
    assert has_element?(view, "#deploy-#{version.id}")
    assert has_element?(view, "#deploy-#{version.id}[href='/apps/#{linked_app.slug}/deploy']")

    assert index_of(html, "data-testid=\"cta-section\"") <
             index_of(html, "data-testid=\"versions-heading\"")

    assert has_element?(
             view,
             "[data-testid='price-#{version.version}']",
             "$1.00/mo · billed hourly"
           )

    # #558: the badges price through Pricing.version_rates/1 — the
    # recommended compute class's rate plus the storage axis at the
    # version's own default GB (stopped is the storage alone). The
    # pinned figure stays "$1.00" because the fixture's storage default
    # is 0 GB; the expectation itself comes from the seam, not a literal.
    loaded = Ash.load!(version, :recommended_size, authorize?: false)
    rates = Pricing.version_rates(loaded)

    assert rates.monthly_cents == 100

    assert has_element?(
             view,
             "[data-testid='price-#{version.version}']",
             Pricing.format_monthly_rate(rates.monthly_cents)
           )

    # The pricing card states the same figure off the same seam.
    assert has_element?(
             view,
             "#pricing-card",
             Pricing.format_usd(rates.monthly_cents)
           )

    # An already-signed-in reader is not sold the signup grant.
    refute has_element?(view, "#pricing-card", "welcome credit")

    assert has_element?(
             view,
             "[data-testid='stopped-price-#{version.version}']",
             "#{Pricing.format_usd(rates.stopped_monthly_cents)}/mo while stopped"
           )

    # #558: /pricing carries no sizes table — the link is the plain
    # page, and the testid keeps its see-all-sizes name (stable hook).
    assert has_element?(
             view,
             "[data-testid='see-all-sizes-#{version.version}'][href='/pricing']",
             "See pricing"
           )

    assert html =~ "First FluxVale catalog release."
    assert html =~ "Published"
  end

  # S4's curated sections are data-driven; the LiveView must pass the
  # loaded app through unchanged, so authored screenshots and features
  # render here exactly as on the public page.
  test "an authored app renders the in-action and features sections", %{conn: conn} do
    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, [app: :category], authorize?: false).app

    authored =
      App.update!(
        app,
        %{
          in_action_intro: "The real interface, captured from a running instance.",
          screenshots: [
            %{
              src: "/images/catalog/screenshots/authored-1440.png",
              alt: "The dashboard",
              caption: "Tasks in one view"
            }
          ],
          features: [
            %{icon: "hero-bolt", title: "Fast", body: "Every list loads in a single request."},
            %{
              icon: "hero-key",
              title: "Private",
              body: "Sign in with your own Pocket ID account."
            }
          ]
        },
        authorize?: false
      )

    {:ok, view, _html} = live(conn, ~p"/apps/#{authored.slug}")

    assert has_element?(view, "[data-testid='in-action-section']", "Tasks in one view")
    assert has_element?(view, "[data-testid='features-section']", "Fast")
    assert has_element?(view, "[data-testid='features-section']", "Private")

    assert index_of(render(view), "data-testid=\"features-section\"") <
             index_of(render(view), "data-testid=\"benefits-section\"")
  end

  test "a version without a recommended size shows no price (pre-#125 row)", %{conn: conn} do
    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, :app, authorize?: false).app

    # States actions can't produce: the pre-#125 shape — nil size.
    Ash.Seed.seed!(FluxVale.Catalog.AppVersion, %{
      version: "0.9.0",
      sort_key: SetSortKey.key("0.9.0"),
      image: "test/image:0.9",
      port: 3000,
      app_id: app.id
    })

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}")

    assert has_element?(view, "[data-testid='price-#{version.version}']")

    refute has_element?(view, "[data-testid='price-0.9.0']")
    # #398: the stopped line hides with the price; the ladder link stays.
    refute has_element?(view, "[data-testid='stopped-price-0.9.0']")
    assert has_element?(view, "[data-testid='see-all-sizes-0.9.0']")
  end

  test "unknown slug redirects back to the catalog with a flash", %{conn: conn} do
    case live(conn, ~p"/apps/nope") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end

  # An app can exist before its first version — the pricing card and its
  # Deploy CTA would open a stepper with nothing to pick (#341 review,
  # the public page's no-versions rule in S2).
  test "an app with no versions renders without a deploy CTA", %{conn: conn} do
    n = System.unique_integer()

    category =
      Category.create!(
        %{
          name: "Empty #{n}",
          slug: "empty-#{n}",
          description: "Test category #{n} — the index's category line."
        },
        authorize?: false
      )

    _app =
      App.create!(
        %{name: "Bare #{n}", slug: "bare-#{n}", category_id: category.id},
        authorize?: false
      )

    {:ok, view, html} = live(conn, ~p"/apps/bare-#{n}")

    assert has_element?(view, "h1", "Bare #{n} hosting")
    # The hero still renders, and the facts card drops its version rows.
    refute has_element?(view, "#pricing-card")
    refute has_element?(view, "[data-testid='deploy-cta']")
    refute has_element?(view, "[data-testid='cta-deploy']")
    # The gate's companion (#341 hostile F7): the Versions heading isn't
    # a dead end — the empty state carries the next step's absence.
    assert has_element?(view, "[data-testid='versions-heading']", "Versions")
    assert html =~ "No versions published yet."
    refute has_element?(view, "a[href='/apps/bare-#{n}/deploy']")
  end

  # #190: the catalog-declared file-access flag surfaces as a pricing
  # card row — the deploy-time surface for "this app's instances carry
  # WebDAV" (the public page's S2 idiom).
  test "a file-access app shows the WebDAV row; others don't", %{conn: conn} do
    version = InstanceFixtures.app_version!(file_access: true)
    app = Ash.load!(version, :app, authorize?: false).app

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}")

    assert has_element?(view, "[data-testid='check-webdav']", "Move files in over WebDAV")

    plain = InstanceFixtures.app_version!()
    plain_app = Ash.load!(plain, :app, authorize?: false).app

    {:ok, plain_view, _html} = live(conn, ~p"/apps/#{plain_app.slug}")

    refute has_element?(plain_view, "[data-testid='check-webdav']")
  end
end
