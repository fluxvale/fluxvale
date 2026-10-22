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
end
