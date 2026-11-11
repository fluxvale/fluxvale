defmodule FluxValeWeb.AppAnalyticsTest do
  # async: false — the render tests mutate the global :posthog app env
  # (read at render time by the component, the plugs, and any module
  # rendering the chrome); it must not race sibling modules.
  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.TestSupport.SessionHelpers

  describe "the hook element" do
    test "renders nothing at all while unarmed" do
      stub_posthog(nil)

      html = render_app_analytics(nil)

      assert html == ""
    end

    test "renders the hook with the armed config, no distinct id without a user" do
      stub_posthog(%{api_host: "https://eu.i.posthog.com", api_key: "phc_test_app_analytics"})

      html = render_app_analytics(nil)

      assert html =~ ~s(id="posthog-config")
      assert html =~ ~s(data-api-host="https://eu.i.posthog.com")
      assert html =~ ~s(data-api-key="phc_test_app_analytics")
      refute html =~ "data-distinct-id"
    end

    test "carries the resolved user's id as the distinct id" do
      stub_posthog(%{api_host: "https://eu.i.posthog.com", api_key: "phc_test_app_analytics"})
      user = SessionHelpers.user!()

      html = render_app_analytics(user)

      assert html =~ ~s(data-distinct-id="#{user.id}")
    end
  end

  describe "placement (ADR-0049's layering)" do
    test "renders on the signed-in app surface with the config and identity", %{conn: conn} do
      stub_posthog(%{api_host: "https://eu.i.posthog.com", api_key: "phc_test_app_analytics"})

      {user, session_conn} = SessionHelpers.user_with_session(conn)
      html = html_response(get(session_conn, ~p"/"), 200)

      assert html =~ ~s(id="posthog-config")
      assert html =~ ~s(data-api-key="phc_test_app_analytics")
      assert html =~ ~s(data-distinct-id="#{user.id}")
    end

    test "never renders on the public surface even when armed (Umami's layer)", %{conn: conn} do
      stub_posthog(%{api_host: "https://eu.i.posthog.com", api_key: "phc_test_app_analytics"})

      landing = html_response(get(conn, ~p"/"), 200)
      blog = html_response(get(conn, ~p"/blog"), 200)

      for html <- [landing, blog] do
        refute html =~ "posthog-config"
      end
    end
  end

  defp render_app_analytics(current_user) do
    render_component(&FluxValeWeb.AppAnalytics.app_analytics/1, current_user: current_user)
  end

  # Sets :posthog for the current test and restores whatever came
  # before (the stub_site_analytics shape) — assertions own their
  # preconditions.
  defp stub_posthog(value) do
    previous = Application.get_env(:flux_vale, :posthog)

    Application.put_env(:flux_vale, :posthog, value)

    on_exit(fn ->
      if previous do
        Application.put_env(:flux_vale, :posthog, previous)
      else
        Application.delete_env(:flux_vale, :posthog)
      end
    end)
  end
end
