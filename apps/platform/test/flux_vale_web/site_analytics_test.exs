defmodule FluxValeWeb.SiteAnalyticsTest do
  # async: false — the render tests mutate the global :site_analytics app
  # env (read at render time by the component); it must not race sibling
  # modules that render the public chrome.
  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.SiteAnalytics

  describe "from_env/2" do
    test "both halves set resolves the config pair" do
      assert {:ok, [script_url: "https://umami.example.com/script.js", website_id: "wid-1"]} =
               SiteAnalytics.from_env("https://umami.example.com/script.js", "wid-1")
    end

    test "both blank (nil or the empty-Secret shape) is the unset default" do
      assert :unset = SiteAnalytics.from_env(nil, nil)
      assert :unset = SiteAnalytics.from_env("", "")
    end

    test "one half without the other reports the half-configuration" do
      assert {:error, :half_configured} = SiteAnalytics.from_env("https://u/script.js", nil)
      assert {:error, :half_configured} = SiteAnalytics.from_env(nil, "wid-1")
      assert {:error, :half_configured} = SiteAnalytics.from_env("https://u/script.js", "")
    end
  end

  describe "the public layout's script tag (#576)" do
    test "renders nothing at all while unconfigured", %{conn: conn} do
      stub_site_analytics(nil)

      # Both public surfaces: the self-contained landing and the
      # Layouts.public chrome (the blog carries it).
      landing = html_response(get(conn, ~p"/"), 200)
      blog = html_response(get(conn, ~p"/blog"), 200)

      for html <- [landing, blog] do
        refute html =~ ~s(data-website-id=)
        refute html =~ ~s(<script async src="https://)
      end
    end

    test "a hand-set half config still renders nothing (the pair is atomic)", %{conn: conn} do
      # runtime.exs drops half-configured env pairs to nil, but a
      # release overlay or a stray Application.put_env can set exactly
      # one key — the component's own guard is the backstop, and this
      # is the arm that guard exists for.
      stub_site_analytics(script_url: "https://umami.example.com/script.js")

      landing = html_response(get(conn, ~p"/"), 200)

      refute landing =~ ~s(data-website-id=)
      refute landing =~ ~s(src="https://umami.example.com/script.js")
    end

    test "renders the tracker on the public surfaces when configured", %{conn: conn} do
      stub_site_analytics(
        script_url: "https://umami.example.com/script.js",
        website_id: "e2e-website-id"
      )

      landing = html_response(get(conn, ~p"/"), 200)
      blog = html_response(get(conn, ~p"/blog"), 200)

      # Attribute-order tolerant: the test endpoint adds LV debug attrs
      # to the tag, so assert the three load-bearing parts.
      for html <- [landing, blog] do
        assert html =~ ~r/<script[^>]*\basync\b/
        assert html =~ ~s(src="https://umami.example.com/script.js")
        assert html =~ ~s(data-website-id="e2e-website-id")
      end
    end

    test "never renders on the authenticated surface", %{conn: conn} do
      stub_site_analytics(
        script_url: "https://umami.example.com/script.js",
        website_id: "e2e-website-id"
      )

      # The session-aware root swaps the landing for the dashboard —
      # the app surface must stay untracked even when configured.
      {_user, session_conn} = SessionHelpers.user_with_session(conn)

      html = html_response(get(session_conn, ~p"/"), 200)

      assert html =~ ~s(data-testid="dashboard-balance")
      refute html =~ ~s(data-website-id=)
    end
  end

  # Sets :site_analytics for the current test and restores whatever came
  # before (the stub_build_sha shape) — assertions own their
  # preconditions.
  defp stub_site_analytics(value) do
    previous = Application.get_env(:flux_vale, :site_analytics)

    if value do
      Application.put_env(:flux_vale, :site_analytics, value)
    else
      Application.put_env(:flux_vale, :site_analytics, nil)
    end

    on_exit(fn -> Application.put_env(:flux_vale, :site_analytics, previous) end)
  end
end
