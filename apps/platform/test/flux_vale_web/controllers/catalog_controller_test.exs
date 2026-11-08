defmodule FluxValeWeb.CatalogControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.Seeds
  alias FluxVale.Seeds.CatalogData
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures
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

    # #462: the anonymous chrome's sign-in links carry the page back
    # through sign-in (the chrome attr threads MaybeResolveUser's assign).
    test "anonymous chrome sign-in links carry the return path", %{conn: conn} do
      app = catalog_app!()

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      assert html =~ ~s(href="/sign-in?return_to=%2Fcatalog%2F#{app.slug}")
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
      assert html =~ to_string(AccountsFixtures.primary_address!(user))
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
      assert html =~
               ~s(name="description" content="A curated catalog of open source apps, ready to run in minutes.")

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

    # #398 + #558: the cards carry the compute floor — "from $X/mo ·
    # billed hourly plus storage", the same computed number on every
    # card (any app at the same compute class costs the same; storage
    # prices per GB on top, so the copy says so). Expectation from a
    # Size read, never a literal.
    test "cards carry the computed from-price floor", %{conn: conn} do
      catalog_app!()
      PricingFixtures.size!(monthly_cents: 701)
      PricingFixtures.size!(monthly_cents: 233)

      sizes =
        Size
        |> Ash.Query.for_read(:read, %{}, actor: nil)
        |> Ash.read!()

      cheapest = Enum.min_by(sizes, & &1.monthly_cents)

      conn = get(conn, ~p"/catalog")
      html = html_response(conn, 200)

      assert html =~
               "from #{Pricing.format_monthly_rate(cheapest.monthly_cents)} plus storage"

      assert html =~ ~s(data-testid="from-price")
    end

    # The reprice follows: a fixture Size update moves the card number —
    # the floor is computed at request time, never cached or literal.
    test "the from-price follows a fixture reprice", %{conn: conn} do
      catalog_app!()
      cheapest = PricingFixtures.size!(monthly_cents: 233)
      PricingFixtures.size!(monthly_cents: 701)

      assert html_response(get(conn, ~p"/catalog"), 200) =~
               "from #{Pricing.format_monthly_rate(233)} plus storage"

      Size.update!(cheapest, %{monthly_cents: 99}, authorize?: false)

      html = html_response(get(conn, ~p"/catalog"), 200)

      assert html =~ "from #{Pricing.format_monthly_rate(99)} plus storage"
      refute html =~ "from #{Pricing.format_monthly_rate(233)} plus storage"
    end

    # The empty-table branch: an unseeded table renders the cards
    # without the from-price line (the controller passes nil), never a
    # crash.
    test "cards hide the from-price line on an unseeded table", %{conn: conn} do
      catalog_app!()

      html = html_response(get(conn, ~p"/catalog"), 200)

      assert html =~ "App catalog"
      refute html =~ "data-testid=\"from-price\""
    end

    # The gate is a nil-check, not a truthy one: monthly_cents allows 0,
    # and a $0 floor is still a floor.
    test "a zero-priced floor still renders the from-price line", %{conn: conn} do
      catalog_app!()
      PricingFixtures.size!(monthly_cents: 0)

      html = html_response(get(conn, ~p"/catalog"), 200)

      assert html =~ "from #{Pricing.format_monthly_rate(0)} plus storage"
    end
  end

  describe "GET /catalog/:slug" do
    # The S2 hero's happy path (#611 plan §6.3): every curated slot
    # filled, so the present-arm of each conditional is asserted once
    # here and the absent-arms get their own tests below.
    test "renders the hero: eyebrow, title, lead, curated prose, link row, both cards", %{
      conn: conn
    } do
      version =
        InstanceFixtures.app_version!(
          published_at: DateTime.add(DateTime.utc_now(), -3, :day),
          default_cpu_cores: Decimal.new("0.5"),
          default_memory_mb: 512,
          default_storage_gb: 10
        )

      app_row = Ash.load!(version, [app: :category], authorize?: false).app

      Category.update!(
        app_row.category,
        %{audience: "A fit for teams that want their own source control."},
        authorize?: false
      )

      app =
        App.update!(
          app_row,
          %{
            icon_url: "https://example.com/icon.png",
            description: "A git forge with issues and pull requests.\nSecond authored paragraph.",
            source_url: "https://example.com/src",
            docs_url: "https://example.com/docs",
            community_url: "https://example.com/community",
            caveats: [
              "Git works over HTTPS only. SSH pushes and pulls are disabled on every instance.",
              "Email sending is off until you enable it with SMTP settings at deploy."
            ],
            alternatives: ["GitHub", "GitLab"]
          },
          authorize?: false
        )

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      # Hero shape: back link, category eyebrow, display title, lead.
      assert html =~ ~s(href="/catalog")
      assert html =~ app_row.category.name
      assert html =~ "#{app.name} hosting"

      # The icon-led title row (plan §3, review ruling): the tile
      # renders the icon decoratively — the h1 names the app.
      assert html =~ ~s(data-testid="app-icon")

      assert [_tile_with_img] =
               Regex.run(
                 ~r{data-testid="app-icon"[^>]*>\s*<img[^>]*src="https://example\.com/icon\.png"[^>]*alt=""},
                 html
               )

      assert html =~ "Managed #{app.name}, ready in minutes."
      assert html =~ "A git forge with issues and pull requests."

      # Curated slots (S1 metadata): audience, caveats, alternatives.
      assert html =~ "A fit for teams that want their own source control."
      assert html =~ "Worth knowing"

      for caveat <- app.caveats, do: assert(html =~ caveat)

      assert html =~ "An alternative to GitHub and GitLab."

      # Link row: every exit with its URL. No FAQ anchor until S3.
      assert html =~ ~s(href="https://example.com/src")
      assert html =~ "Source"
      assert html =~ ~s(href="https://example.com/docs")
      assert html =~ "Docs"
      assert html =~ ~s(href="https://example.com/community")
      assert html =~ "Community"
      refute html =~ ~s(href="#faq")

      # Pricing card: the rate and specs from the same seams the deploy
      # stepper prices through (the S2 done-when), never literals.
      loaded = Ash.load!(version, :recommended_size, authorize?: false)
      rates = Pricing.version_rates(loaded)

      assert html =~ "Starts at"
      assert html =~ "#{Pricing.format_usd(rates.monthly_cents)}/mo"
      assert html =~ "billed hourly from your wallet"
      assert html =~ "Recommended size"
      assert html =~ "0.5 CPU"
      assert html =~ "512 MB RAM"
      assert html =~ "10 GB storage"

      amount = Pricing.format_usd(Accounts.welcome_grant_cents())
      assert html =~ "Start with #{amount} in welcome credit"
      assert html =~ "Free HTTPS on a fluxvale.app address"
      assert html =~ "Sleeps when idle, wakes on the next visit"
      assert html =~ "Nightly backups to your own S3 bucket"

      assert html =~ ~s(href="/apps/#{app.slug}/deploy")
      assert html =~ "Deploy #{app.name}"
      assert html =~ "Monthly equivalent, billed hourly."

      # Facts card: version, relative age, the constants.
      assert html =~ ~s(data-testid="fact-version")
      assert html =~ "v#{version.version}"
      assert html =~ ~s(data-testid="fact-updated")
      assert html =~ "3d ago"
      assert html =~ "Nuremberg, EU"
      assert html =~ "Your S3 bucket"
    end

    # Omission is a designed state (plan §5): each curated slot
    # disappears without a layout hole.
    test "omits caveats, alternatives, and the community link when absent", %{conn: conn} do
      version = InstanceFixtures.app_version!()
      app = Ash.load!(version, [app: :category], authorize?: false).app

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      assert html =~ "#{app.name} hosting"
      refute html =~ "Worth knowing"
      refute html =~ "An alternative to"
      refute html =~ "Community"
    end

    # The tile's fallback (the catalog's icon-less idiom): the app's
    # initial rides where the img would.
    test "an icon-less app renders the initial in the hero tile", %{conn: conn} do
      version = InstanceFixtures.app_version!()
      app = Ash.load!(version, :app, authorize?: false).app

      refute app.icon_url

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      assert html =~ "#{app.name} hosting"

      assert [_tile_with_initial] =
               Regex.run(
                 ~r{data-testid="app-icon"[^>]*>\s*<span[^>]*>#{String.first(app.name)}</span>},
                 html
               )

      refute html =~ "https://example.com/icon.png"
    end

    # The nil fields are the sanctioned nullable shape (the OpenAPI
    # stance): a YAML `caveats:` null seeds nil through update, and
    # `nil != []` would let the for crash the public page — the hero
    # must treat nil exactly like the absent state (hostile-pass F1).
    test "nil caveats and alternatives render as absent, not a 500", %{conn: conn} do
      version = InstanceFixtures.app_version!()
      app_row = Ash.load!(version, [app: :category], authorize?: false).app

      app =
        App.update!(app_row, %{caveats: nil, alternatives: nil}, authorize?: false)

      assert is_nil(app.caveats)
      assert is_nil(app.alternatives)

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      assert html =~ "#{app.name} hosting"
      assert html =~ ~s(id="facts-card")
      refute html =~ "Worth knowing"
      refute html =~ "An alternative to"
    end

    # The audience line is category-owned: present and cleared on the
    # same app, so the absent-arm refutes a sentence the page carried.
    test "the category's audience line drops when cleared", %{conn: conn} do
      version = InstanceFixtures.app_version!()
      app_row = Ash.load!(version, [app: :category], authorize?: false).app

      # Hold the updated record: the clear must run against it, or the
      # nil-to-nil diff on the stale record is a no-op.
      category =
        Category.update!(app_row.category, %{audience: "A fit for note takers."},
          authorize?: false
        )

      assert html_response(get(conn, ~p"/catalog/#{app_row.slug}"), 200) =~
               "A fit for note takers."

      Category.update!(category, %{audience: nil}, authorize?: false)

      refute html_response(get(conn, ~p"/catalog/#{app_row.slug}"), 200) =~
               "A fit for note takers."
    end

    # The OIDC declaration is per-version: either surface counts (the
    # oidc_callback_path stance), Pocket ID itself declares neither.
    test "the Pocket ID checklist row and SSO fact ride the version's OIDC declaration", %{
      conn: conn
    } do
      wired = InstanceFixtures.app_version!(oidc_callback_path: "/signin-oidc")
      wired_app = Ash.load!(wired, :app, authorize?: false).app

      html = html_response(get(conn, ~p"/catalog/#{wired_app.slug}"), 200)

      assert html =~ "Sign in with your Pocket ID"
      assert html =~ ~s(data-testid="fact-sso")

      bare = InstanceFixtures.app_version!()
      bare_app = Ash.load!(bare, :app, authorize?: false).app

      bare_html = html_response(get(conn, ~p"/catalog/#{bare_app.slug}"), 200)

      refute bare_html =~ "Sign in with your Pocket ID"
      refute bare_html =~ ~s(data-testid="fact-sso")
    end

    test "the WebDAV checklist row and File access fact ride app.file_access", %{conn: conn} do
      version = InstanceFixtures.app_version!(file_access: true)
      app = Ash.load!(version, :app, authorize?: false).app

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      assert html =~ "Move files in over WebDAV"
      assert html =~ ~s(data-testid="fact-file-access")

      plain = InstanceFixtures.app_version!()
      plain_app = Ash.load!(plain, :app, authorize?: false).app

      plain_html = html_response(get(conn, ~p"/catalog/#{plain_app.slug}"), 200)

      refute plain_html =~ "Move files in over WebDAV"
      refute plain_html =~ ~s(data-testid="fact-file-access")
    end

    # The pre-#125 shape (nil recommended_size) hides the whole rate
    # group — "Starts at" without a figure is meaningless — while the
    # specs and CTA stay (the price_badge rule, never a crash).
    test "a sizeless newest version hides the rate, keeps specs and CTA", %{conn: conn} do
      version = InstanceFixtures.app_version!()
      app = Ash.load!(version, :app, authorize?: false).app

      # States actions can't produce: the pre-#125 shape — nil size.
      Ash.Seed.seed!(FluxVale.Catalog.AppVersion, %{
        version: "9.9.9",
        image: "test/image:9.9",
        port: 3000,
        app_id: app.id
      })

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      refute html =~ "Starts at"
      assert html =~ "Recommended size"
      assert html =~ "v9.9.9"
      assert html =~ ~s(data-testid="deploy-cta")
    end

    # No versions: the pricing card and CTA hide (the authenticated
    # page's rule), the facts card stays with its constant rows.
    test "an app with no versions hides the pricing card and CTA, keeps the facts card", %{
      conn: conn
    } do
      app = catalog_app!()

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      assert html =~ "#{app.name} hosting"
      refute html =~ ~s(id="pricing-card")
      refute html =~ ~s(data-testid="deploy-cta")
      refute html =~ "Recommended size"
      assert html =~ ~s(id="facts-card")
      assert html =~ "Nuremberg, EU"
      assert html =~ "Your S3 bucket"
      refute html =~ ~s(data-testid="fact-version")
      refute html =~ ~s(data-testid="fact-updated")
    end

    test "a version without published_at hides the Updated row", %{conn: conn} do
      version = InstanceFixtures.app_version!()
      app = Ash.load!(version, :app, authorize?: false).app

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      assert html =~ ~s(data-testid="fact-version")
      refute html =~ ~s(data-testid="fact-updated")
    end

    # PromEx is down in the test env, so the safe wrapper answers %{}
    # — no Wakes in row, never a crash (the catalog index's posture).
    test "absent wake data hides the Wakes in row", %{conn: conn} do
      version = InstanceFixtures.app_version!()
      app = Ash.load!(version, :app, authorize?: false).app

      html = html_response(get(conn, ~p"/catalog/#{app.slug}"), 200)

      refute html =~ ~s(data-testid="fact-wakes")
    end

    # #611 S1+S2 (joined by #587's Umami entry): every seeded app
    # renders the hero off the real seed YAML, whatever the catalog
    # grows to — the app list is derived, never a literal. Curated
    # depth stays per-app honest: the retro-filled apps carry caveats
    # and alternatives; the absent-arms are pinned by the fixture
    # tests above, so no app's curation state is frozen here.
    test "every seeded app renders the hero", %{conn: conn} do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      seeded =
        for entry <- CatalogData.entries(),
            app <- entry.apps do
          app.slug
        end

      assert "forgejo" in seeded
      assert "umami" in seeded

      for slug <- seeded do
        html = html_response(get(conn, ~p"/catalog/#{slug}"), 200)

        assert html =~ "hosting"
        assert html =~ ~s(id="pricing-card")
        assert html =~ ~s(data-testid="deploy-cta")
      end

      # The retro-filled six: the honest hero renders their curated
      # slots.
      for slug <- ~w(forgejo kavita memos vaultwarden pocket-id actualbudget) do
        html = html_response(get(conn, ~p"/catalog/#{slug}"), 200)

        assert html =~ "Worth knowing"
        assert html =~ "An alternative to"
      end

      # Umami (#587) rounds out the loop on the minimum contract — its
      # curation depth is #620's concern, not pinned here.

      # Kavita is the file-access flagship; Pocket ID declares no OIDC
      # consumer surface of its own (it is the provider).
      kavita = html_response(get(conn, ~p"/catalog/kavita"), 200)
      assert kavita =~ "Move files in over WebDAV"
      assert kavita =~ ~s(data-testid="fact-file-access")

      pocket_id = html_response(get(conn, ~p"/catalog/pocket-id"), 200)
      refute pocket_id =~ ~s(data-testid="check-sso")
      refute pocket_id =~ ~s(data-testid="fact-sso")

      # Vaultwarden wires SSO through the #597 recipe.
      vaultwarden = html_response(get(conn, ~p"/catalog/vaultwarden"), 200)
      assert vaultwarden =~ "Sign in with your Pocket ID"
    end

    test "meta: branded title, description, canonical, and the JSON-LD payload", %{conn: conn} do
      app = catalog_app!()

      html =
        conn
        |> get(~p"/catalog/#{app.slug}")
        |> html_response(200)

      # #611 plan §9: the title matches the H1 and the search intent.
      assert [_match, title] = Regex.run(~r{<title[^>]*>(.*)</title>}s, html)
      assert title == "#{app.name} hosting · FluxVale"
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
