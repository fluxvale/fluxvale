defmodule FluxValeWeb.LocaleTest do
  @moduledoc false

  # The locale plumbing: session → plug → Gettext → rendered HEEx, plus
  # the on_mount arms. The swap proof (locale "xx") rides the app
  # layout's error-flash title ("Something went wrong!"), which renders
  # on every page; the root layout carries the matching lang attribute.
  # Every wiring point is tested: the :authenticated live_session via
  # the signed-in dashboard and /apps, the sign-in module hook via
  # /sign-in. The probe LiveView mounts the hook directly for the
  # arm-level checks.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.TestSupport.LocaleProbeLive
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.Locale

  test "init/1 passes opts through", _context do
    assert Locale.init([]) == []
  end

  test "resolve/1: a known session locale wins, everything else falls back", _context do
    assert Locale.resolve(%{"locale" => "xx"}) == "xx"
    # Unknown, missing, and non-binary values all land on the default.
    assert Locale.resolve(%{"locale" => "zz"}) == "en"
    assert Locale.resolve(%{}) == "en"
    assert Locale.resolve(%{"locale" => 7}) == "en"
  end

  test "default: / renders lang=en with English copy", %{conn: conn} do
    body =
      conn
      |> get(~p"/")
      |> html_response(200)

    assert body =~ ~s(lang="en")
    assert body =~ "Something went wrong!"
    refute body =~ "xx: Something went wrong!"
  end

  # The load-bearing swap proof: the whole chain session → plug →
  # Gettext → rendered HEEx, end to end.
  test "session locale xx swaps the render", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("locale", "xx")

    body =
      conn
      |> get(~p"/")
      |> html_response(200)

    assert body =~ "xx: Something went wrong!"
    assert body =~ ~s(lang="xx")
    refute body =~ ~s(lang="en")
  end

  # The landing's extracted copy rides the same chain: the page's own
  # headline swaps, not just the layout chrome around it — and the
  # root layout's <title> swaps with it (:page_title is gettext'd).
  test "session locale xx swaps the landing copy", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("locale", "xx")

    body =
      conn
      |> get(~p"/")
      |> html_response(200)

    assert body =~ "xx: Managed hosting for open source applications"
    assert body =~ "xx: FluxVale — Managed hosting for open source applications"
    assert body =~ ~s(lang="xx")
  end

  test "unknown session locale zz falls back to the default", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("locale", "zz")

    body =
      conn
      |> get(~p"/")
      |> html_response(200)

    assert body =~ ~s(lang="en")
    assert body =~ "Something went wrong!"
    refute body =~ "xx: Something went wrong!"
  end

  test "on_mount :set_locale applies the session locale in the LiveView process", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, LocaleProbeLive, session: %{"locale" => "xx"})

    assert has_element?(view, "#locale-probe", "xx")
  end

  test "on_mount :set_locale falls back to the default without a session locale", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, LocaleProbeLive, session: %{})

    assert has_element?(view, "#locale-probe", "en")
  end

  # The live_session bypass: the signed-in `/` dashboard renders through
  # `live_render`, so DashboardLive declares the locale hook itself
  # (mirroring its sibling hooks). This asserts the LiveView process's
  # own render — the fork the isolated probe cannot see.
  test "signed-in / dashboard renders the session locale in the LiveView process", %{conn: conn} do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)
    conn = Plug.Conn.put_session(session_conn, "locale", "xx")

    {:ok, view, _html} = live(conn, ~p"/")
    assert render(view) =~ "xx: Something went wrong!"
  end

  # The other half of the live_session wiring: the router applies the
  # hook to every :authenticated route — deleting the tuple from the
  # router's on_mount list fails this test.
  test "signed-in /apps renders the session locale in the LiveView process", %{conn: conn} do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)
    conn = Plug.Conn.put_session(session_conn, "locale", "xx")

    {:ok, view, _html} = live(conn, ~p"/apps")
    assert render(view) =~ "xx: Something went wrong!"
  end

  # The anonymous surface: /sign-in sits outside any live_session, so
  # SignIn declares the hook at module level — deleting that on_mount
  # fails this test.
  test "/sign-in renders the session locale in the LiveView process", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("locale", "xx")

    {:ok, view, _html} = live(conn, ~p"/sign-in")
    assert render(view) =~ "xx: Something went wrong!"
  end
end
