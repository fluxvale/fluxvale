defmodule FluxValeWeb.PageControllerTest do
  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.PricingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  # The root layout's <title> suffix is " · Phoenix Framework" — boilerplate
  # this PR doesn't own — so the scaffold regression guard asserts on the
  # rendered <body> rather than the whole document.
  defp landing_body(html) do
    html
    |> String.split("<body>")
    |> List.last()
  end

  test "GET / renders the landing page", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    body = landing_body(html)

    assert html =~ ~r/<h1[^>]*>\s*Managed cloud platform for open source applications/
    assert html =~ "FluxVale, managed cloud platform for open source applications"
    assert html =~ ~s(href="/catalog")
    assert html =~ ~s(href="/sign-in")
    # The sign-in redirect target is this page — its flash must render here.
    assert html =~ ~s(id="flash-group")

    assert body =~ ">Apps</a>"
    assert body =~ ~r/>Sign in/
    assert body =~ "How it works"
    assert body =~ "Pick an app"
    assert body =~ "No YAML"
    assert body =~ "We run it"
    assert body =~ "Simple pricing"
    assert body =~ "a welcome credit"
    assert body =~ "© #{Date.utc_today().year} FluxVale"

    # Phoenix scaffold regression guard — the old page must stay gone.
    refute body =~ "Phoenix Framework"
    refute body =~ "Peace of mind from prototype to production"

    assert conn.assigns[:page_title] =~ "managed cloud platform for open source applications"
    assert conn.assigns[:page_description] =~ "deploy"
  end

  # fv332 D5: the landing's own footer (foot-links, distinct from the
  # chrome footer) carries the legal set — privacy lands beside terms
  # and acceptable use.
  test "GET / footer links the legal pages including privacy", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(data-testid="footer-terms")
    assert html =~ ~s(data-testid="footer-acceptable-use")
    assert html =~ ~s(data-testid="footer-privacy")
    assert html =~ ~s(href="/policies/privacy")
  end

  # Brand drop-in (#277): the nav carries the mark pair — the dark render
  # is the hero treatment, flipped by the Tailwind `dark:` variant — and
  # the root layout's head carries the favicon set (SVG pair + PNGs + ICO).
  # The chrome's home link is asserted on /catalog (the public chrome's
  # render), the landing's own header on /: both name the link regardless
  # of theme or width (aria-label on the chrome link; the landing's
  # wordmark span is always visible).
  test "GET / and /catalog carry the brand mark pair, favicon links, and a named home link", %{
    conn: conn
  } do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(src="/images/mark.svg")
    assert html =~ ~s(src="/images/mark-dark.svg")
    assert html =~ ~s(href="/images/favicon-dark.svg")
    assert html =~ ~s(href="/images/favicon.svg")
    assert html =~ ~s(href="/images/favicon-32.png")
    assert html =~ ~s(href="/images/favicon-16.png")
    assert html =~ ~s(href="/favicon.ico")

    # The chrome (public surfaces like /catalog) hides the wordmark below
    # 300px and the light mark in dark mode — the link's aria-label is the
    # one name that survives every combination.
    chrome = get(conn, ~p"/catalog")
    chrome_html = html_response(chrome, 200)

    assert chrome_html =~ ~s(src="/images/mark.svg")
    assert chrome_html =~ ~s(src="/images/mark-dark.svg")
    assert chrome_html =~ ~s(aria-label="FluxVale")
  end

  # The hero panel is the real product: FluxVale chrome (the address
  # bar names the product origin) around a captured app page — the
  # dummy-instance mock (ghostboard/wiki/forum) is gone for good, so
  # its names must never render again. The float chip states the
  # capture's honesty in mono text.
  test "GET / renders the hero panel with its float chip", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(class="path">fluxvale.com</span>)
    assert html =~ ~s(src="/images/landing/hero-app-page-light.png")
    assert html =~ ~s(src="/images/landing/hero-app-page-dark.png")
    assert html =~ "real apps · real prices"

    refute html =~ "app.fluxvale.app"
    refute html =~ "ghostboard"
    refute html =~ "Update to v3.0 ready"
  end

  # The catalog band carries the two app cards — assert the content,
  # not class strings. The split anchors past the band's heading id, so
  # the identical mini-preview copy in the steps can't satisfy these.
  test "GET / renders the catalog band's two app cards", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    band =
      html
      |> String.split("catalog-title")
      |> List.last()

    assert band =~ "Developer Tools"
    assert band =~ "Forgejo"
    assert band =~ "Media &amp; Entertainment"
    assert band =~ "Kavita"
  end

  # #205: GitHub-style session-aware root — a resolved session swaps the
  # landing for the dashboard LiveView, same URL, no redirect.
  test "GET / with a session renders the dashboard, not the landing", %{conn: conn} do
    {user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Dashboard"
    assert html =~ ~s(data-testid="dashboard-balance")
    assert html =~ ~s(data-testid="dashboard-runway")
    # The landing hero is gone; the signed-in chrome carries the user menu.
    refute html =~ ~r/<h1[^>]*>\s*Managed cloud platform for open source applications/
    assert html =~ to_string(AccountsFixtures.primary_address!(user))
    assert html =~ ~s(data-testid="user-menu")
    assert conn.assigns[:page_title] == "FluxVale Dashboard"
  end

  test "GET /about renders the landing for anonymous visitors, canonical to /", %{conn: conn} do
    conn = get(conn, ~p"/about")
    html = html_response(conn, 200)

    assert html =~ ~r/<h1[^>]*>\s*Managed cloud platform for open source applications/
    assert html =~ ~s(rel="canonical" href="https://fluxvale.com/")
  end

  # The launch SEO audit lean: `/` shipped no canonical — and og:url
  # emits only alongside one (FluxValeWeb.Seo). Self-canonical to `/`,
  # so /about's canonical target declares itself the same URL.
  test "GET / self-canonicalizes with og:url", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(rel="canonical" href="https://fluxvale.com/")
    assert html =~ ~s(property="og:url" content="https://fluxvale.com/")
  end

  test "GET /about for a signed-in visitor keeps the landing, swaps the chrome", %{conn: conn} do
    {user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/about")
    html = html_response(conn, 200)

    assert html =~ ~r/<h1[^>]*>\s*Managed cloud platform for open source applications/
    assert html =~ ~s(data-testid="user-menu")
    assert html =~ to_string(AccountsFixtures.primary_address!(user))
    # The signed-in landing points inward, not at sign-in.
    assert html =~ ~s(Your dashboard)
    refute html =~ ~r/class="[^"]*bg-primary[^"]*"[^>]*>\s*Sign in/
  end

  # #255: at 375px the header row (logo + surface links + theme trio +
  # menu) overflowed the viewport by ~133px, dropdown closed. Below sm
  # the app chrome hides its three header links (`hidden sm:block`) and
  # the user menu re-serves Catalog/Instances/Feedback (`sm:hidden`
  # rows) — a fold, not a removal: no width renders both copies, no
  # width loses them. Billing rides the menu at every width (#467) and
  # shows up here without a header copy at any width.
  test "GET / folds the chrome's surface links into the user menu below sm (#255)", %{
    conn: conn
  } do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/")
    html = html_response(conn, 200)

    # Header copies hide below sm…
    assert html =~ ~s(class="hidden sm:block")
    assert html =~ ~s(href="/apps")
    assert html =~ ~s(href="/instances")

    # …and the panel carries the folded rows alongside the every-width
    # Billing row.
    panel =
      html
      |> String.split(~s(data-testid="user-menu-panel"))
      |> List.last()

    assert panel =~ ~s(href="/apps")
    assert panel =~ ~s(href="/instances")
    assert panel =~ ~s(href="/feedback")
    assert panel =~ ~s(href="/billing")
    assert panel =~ "sm:hidden"
  end

  # The landing chrome never had the surface links, so its menu stays
  # fold-free — `app_links` is the app chrome's flag alone. Pricing
  # left the menu entirely (#551): the public chrome's header and
  # footer carry the page instead.
  test "GET /about for a signed-in visitor keeps the menu fold-free (#255)", %{conn: conn} do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/about")
    html = html_response(conn, 200)

    panel =
      html
      |> String.split(~s(data-testid="user-menu-panel"))
      |> List.last()
      # Bound the panel: the unbounded tail would sweep in the landing
      # band's own Pricing button below it.
      |> String.split("</details>")
      |> List.first()

    refute panel =~ ~s(href="/apps")
    refute panel =~ ~s(href="/instances")
    refute panel =~ ~s(href="/pricing")
    assert panel =~ ~s(href="/billing")
  end

  # #551: Pricing and About left the menu — the signed-in app chrome
  # renders no /pricing link at all (the dashboard body links none and
  # the app chrome has no footer). The pages stay public: /pricing via
  # the public chrome's header and footer, /about via the landing.
  test "GET / (signed in) renders no Pricing menu row (#551)", %{
    conn: conn
  } do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/")
    html = html_response(conn, 200)

    assert length(String.split(html, ~s(href="/pricing"))) - 1 == 0

    panel =
      html
      |> String.split(~s(data-testid="user-menu-panel"))
      |> List.last()

    refute panel =~ ~s(href="/pricing")
    refute panel =~ "About FluxVale"
    assert panel =~ ~s(href="/billing")
  end

  # #396 + #558: the band points at /pricing and renders the cheapest
  # compute class's rate with storage named as its own per-GB charge —
  # expectation computed from a Size read, never a literal.
  test "GET / pricing band links at /pricing with the computed floor rate (#396)", %{conn: conn} do
    PricingFixtures.size!(monthly_cents: 401)
    PricingFixtures.size!(monthly_cents: 177)

    sizes =
      Size
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> Ash.Query.sort(:monthly_cents)
      |> Ash.read!()

    floor = Pricing.format_usd(Enum.min_by(sizes, & &1.monthly_cents).monthly_cents)

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "See full pricing"
    assert html =~ ~s(href="/pricing")
    assert html =~ "Compute starts at #{floor}/mo plus per-GB storage"
    assert html =~ "billed hourly while running"
  end

  # The empty-table branch: an unseeded DB renders the band without the
  # floor line (the controller passes nil), never a crash.
  test "GET / pricing band hides the floor line on an unseeded table (#396)", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "See full pricing"
    refute html =~ "Compute starts at"
  end

  # The band's floor gate is a nil-check, not a truthy one (#398 fix
  # round): monthly_cents allows 0, and a $0 floor is still a floor.
  test "GET / pricing band renders a zero-priced floor", %{conn: conn} do
    PricingFixtures.size!(monthly_cents: 0)

    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ "Compute starts at #{Pricing.format_usd(0)}/mo plus per-GB storage"
  end

  # #396: the landing carries the Pricing link in the header nav, the
  # band CTA, and the footer. Whitespace-tolerant matching: the
  # nav_link slot renders with newlines around the label.
  test "GET / carries the Pricing nav, band CTA, and footer links (#396)", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    body =
      html
      |> String.split("<body>")
      |> List.last()

    assert length(String.split(body, ~s(href="/pricing"))) - 1 == 3
    assert body =~ ~r/href="\/pricing"[^>]*>\s*Pricing\s*<\/a>/
  end
end
