defmodule FluxValeWeb.Components.CatalogPageComponentsTest do
  @moduledoc """
  The catalog page's pure display helpers (#611 S2): the alternatives
  join and the relative-age phrase, plus the facts card's wake
  formatting (controller tests cover the page composition; PromEx is
  down there, so the "~Ns" register is pinned here instead).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.CatalogPageComponents

  describe "alternative_to/1 (plan §7.1)" do
    test "one name" do
      assert CatalogPageComponents.alternative_to(["GitHub"]) ==
               "An alternative to GitHub."
    end

    test "two names" do
      assert CatalogPageComponents.alternative_to(["GitHub", "GitLab"]) ==
               "An alternative to GitHub and GitLab."
    end

    test "three or more names — comma list, no Oxford comma" do
      assert CatalogPageComponents.alternative_to(["GitHub", "GitLab", "Gitea"]) ==
               "An alternative to GitHub, GitLab and Gitea."

      assert CatalogPageComponents.alternative_to(["A", "B", "C", "D"]) ==
               "An alternative to A, B, C and D."
    end

    test "empty and nil are the designed absent state" do
      assert CatalogPageComponents.alternative_to([]) == nil
      assert CatalogPageComponents.alternative_to(nil) == nil
    end
  end

  describe "relative_updated/1" do
    test "nil hides the row" do
      assert CatalogPageComponents.relative_updated(nil) == nil
    end

    test "today, yesterday, N days" do
      now = DateTime.utc_now()

      assert CatalogPageComponents.relative_updated(now) == "today"

      yesterday = DateTime.add(now, -1, :day)
      assert CatalogPageComponents.relative_updated(yesterday) == "yesterday"

      three_days = DateTime.add(now, -3, :day)
      assert CatalogPageComponents.relative_updated(three_days) == "3d ago"
    end

    test "a future timestamp clamps to today — seed drift, never a negative age" do
      future = DateTime.add(DateTime.utc_now(), 2, :day)

      assert CatalogPageComponents.relative_updated(future) == "today"
    end
  end

  describe "the facts card's Wakes in row" do
    test "renders the median in the badge's ~estimate register" do
      assigns = %{
        app: %{slug: "kavita", file_access: false},
        newest_version: nil,
        wake_estimates: %{"kavita" => 4.2}
      }

      html = render_component(&CatalogPageComponents.facts_card/1, assigns)

      assert html =~ ~s(data-testid="fact-wakes")
      assert html =~ "~4s"
    end

    test "over a minute reads minutes-and-seconds (the badge's own rule)" do
      assigns = %{
        app: %{slug: "slow", file_access: false},
        newest_version: nil,
        wake_estimates: %{"slow" => 125.4}
      }

      html = render_component(&CatalogPageComponents.facts_card/1, assigns)

      assert html =~ "~2m 5s"
    end
  end
end
