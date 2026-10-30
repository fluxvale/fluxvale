defmodule FluxValeWeb.PageControllerTest do
  use FluxValeWeb.ConnCase, async: true

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

    assert html =~ ~r/<h1[^>]*>\s*Managed hosting for open source applications/
    assert html =~ "FluxVale — Managed hosting for open source applications"
    assert html =~ ~s(href="/catalog")
    assert html =~ ~s(href="/sign-in")
    # The sign-in redirect target is this page — its flash must render here.
    assert html =~ ~s(id="flash-group")

    assert body =~ ">Apps</a>"
    assert body =~ ~r/>Sign in/
    assert body =~ "How it works"
    assert body =~ "Pick an app"
    assert body =~ "no YAML"
    assert body =~ "We run it"
    assert body =~ "Simple pricing"
    assert body =~ "welcome credits"
    assert body =~ "© #{Date.utc_today().year} FluxVale"

    # Phoenix scaffold regression guard — the old page must stay gone.
    refute body =~ "Phoenix Framework"
    refute body =~ "Peace of mind from prototype to production"

    assert conn.assigns[:page_title] =~ "Managed hosting for open source applications"
    assert conn.assigns[:page_description] =~ "deploy"
  end

  # Brand drop-in (#277): the nav carries the mark pair — the dark render
  # is the hero treatment, flipped by the Tailwind `dark:` variant — and
  # the root layout's head carries the favicon set (SVG pair + PNGs + ICO).
  test "GET / carries the brand mark pair and the favicon links", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(src="/images/mark.svg")
    assert html =~ ~s(src="/images/mark-dark.svg")
    assert html =~ ~s(aria-hidden="true" class="hidden dark:block")

    assert html =~ ~s(href="/images/favicon-dark.svg")
    assert html =~ ~s(href="/images/favicon.svg")
    assert html =~ ~s(href="/images/favicon-32.png")
    assert html =~ ~s(href="/images/favicon-16.png")
    assert html =~ ~s(href="/favicon.ico")
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
    refute html =~ ~r/<h1[^>]*>\s*Managed hosting for open source applications/
    assert html =~ to_string(user.email)
    assert html =~ ~s(data-testid="user-menu")
    assert conn.assigns[:page_title] == "FluxVale — Dashboard"
  end

  test "GET /about renders the landing for anonymous visitors, canonical to /", %{conn: conn} do
    conn = get(conn, ~p"/about")
    html = html_response(conn, 200)

    assert html =~ ~r/<h1[^>]*>\s*Managed hosting for open source applications/
    assert html =~ ~s(rel="canonical" href="https://fluxvale.com/")
  end

  test "GET /about for a signed-in visitor keeps the landing, swaps the chrome", %{conn: conn} do
    {user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/about")
    html = html_response(conn, 200)

    assert html =~ ~r/<h1[^>]*>\s*Managed hosting for open source applications/
    assert html =~ ~s(data-testid="user-menu")
    assert html =~ to_string(user.email)
    # The signed-in landing points inward, not at sign-in.
    assert html =~ ~s(Your dashboard)
    refute html =~ ~r/class="[^"]*bg-primary[^"]*"[^>]*>\s*Sign in/
  end

  # #255: at 375px the header row (logo + surface links + theme trio +
  # menu) overflowed the viewport by ~133px, dropdown closed. Below sm
  # the app chrome hides its three header links (`hidden sm:block`) and
  # the user menu re-serves Catalog/Instances (`sm:hidden` rows) — a
  # fold, not a removal: no width renders both copies, no width loses
  # them.
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
    assert html =~ ~s(href="/billing")

    # …and the panel carries the mobile-only rows alongside Billing.
    panel =
      html
      |> String.split(~s(data-testid="user-menu-panel"))
      |> List.last()

    assert panel =~ ~s(href="/apps")
    assert panel =~ ~s(href="/instances")
    assert panel =~ ~s(href="/billing")
    assert panel =~ "sm:hidden"
  end

  # The landing chrome never had the surface links, so its menu stays
  # fold-free — `app_links` is the app chrome's flag alone.
  test "GET /about for a signed-in visitor keeps the menu fold-free (#255)", %{conn: conn} do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/about")
    html = html_response(conn, 200)

    panel =
      html
      |> String.split(~s(data-testid="user-menu-panel"))
      |> List.last()

    refute panel =~ ~s(href="/apps")
    refute panel =~ ~s(href="/instances")
    assert panel =~ ~s(href="/billing")
  end
end
