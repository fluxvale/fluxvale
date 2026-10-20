defmodule FluxValeWeb.PageControllerTest do
  use FluxValeWeb.ConnCase, async: true

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
end
