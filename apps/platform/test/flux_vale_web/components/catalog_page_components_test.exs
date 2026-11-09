defmodule FluxValeWeb.Components.CatalogPageComponentsTest do
  @moduledoc """
  The catalog page's pure display helpers and curated sections (#611
  S2+S4): the alternatives join, the relative-age phrase, the facts
  card's wake formatting (controller tests cover the page composition;
  PromEx is down there, so the "~Ns" register is pinned here instead),
  and the S4 in-action and features sections over plain maps — the
  grid shapes, the image contract, and the designed absent states.
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

  describe "in_action/1 (plan §6.4, S4)" do
    # The Types.ScreenshotList item shape, straight from the S1 cast.
    defp shot(overrides \\ []) do
      base = %{
        src: "/images/catalog/forgejo/repository-list.webp",
        alt: "The repository list inside a running Forgejo instance",
        caption: nil
      }

      Map.merge(base, Map.new(overrides))
    end

    defp render_in_action(app) do
      render_component(&CatalogPageComponents.in_action/1, %{app: app})
    end

    test "nil and [] are the designed absent state — nothing renders, no gap" do
      for screenshots <- [nil, []] do
        app = %{name: "Forgejo", in_action_intro: "An intro.", screenshots: screenshots}
        html = render_in_action(app)

        assert String.trim(html) == ""
      end
    end

    test "two screenshots: eyebrow, h2, authored intro, 2-column grid, both frames" do
      app = %{
        name: "Forgejo",
        in_action_intro: "The real interface, captured from a running instance.",
        screenshots: [
          shot(),
          shot(
            src: "/images/catalog/forgejo/pull-request.webp",
            alt: "A pull request review with inline comments",
            caption: "Reviewing a pull request"
          )
        ]
      }

      html = render_in_action(app)

      assert html =~ ~s(data-testid="in-action-section")
      assert html =~ "In action"
      assert html =~ "Forgejo in action"
      assert html =~ "The real interface, captured from a running instance."
      assert html =~ ~s(class="mt-10 grid gap-4 sm:grid-cols-2")
      assert length(Regex.scan(~r/data-testid="screenshot-frame"/, html)) == 2
    end

    test "one screenshot renders a single wide frame — no 2-column grid" do
      html = render_in_action(%{name: "Forgejo", in_action_intro: nil, screenshots: [shot()]})

      # The single-column grid class renders bare — no sm:grid-cols-2.
      assert html =~ "mt-10 grid gap-4"
      refute html =~ "sm:grid-cols-2"
      assert length(Regex.scan(~r/data-testid="screenshot-frame"/, html)) == 1
    end

    test "three and four screenshots keep the 2-column grid and wrap" do
      for count <- [3, 4] do
        screenshots =
          Enum.map(1..count//1, fn i ->
            shot(src: "/images/catalog/forgejo/view-#{i}.webp", alt: "Interface view #{i}")
          end)

        html =
          render_in_action(%{name: "Forgejo", in_action_intro: nil, screenshots: screenshots})

        assert html =~ ~s(class="mt-10 grid gap-4 sm:grid-cols-2")
        assert length(Regex.scan(~r/data-testid="screenshot-frame"/, html)) == count
      end
    end

    # Plan §6.5: fixed aspect, explicit dimensions, lazy, async — no
    # CLS, no eager image loads on a page that may carry four frames.
    test "images carry src and alt from the data, lazy, async, 16:10 with dimensions" do
      html = render_in_action(%{name: "Forgejo", in_action_intro: nil, screenshots: [shot()]})

      assert html =~ ~s(src="/images/catalog/forgejo/repository-list.webp")
      assert html =~ ~s(alt="The repository list inside a running Forgejo instance")
      assert html =~ ~s(loading="lazy")
      assert html =~ ~s(decoding="async")
      assert html =~ ~s(width="1440")
      assert html =~ ~s(height="900")
      assert html =~ ~s(class="aspect-[16/10] w-full object-cover")
    end

    test "the caption renders when authored and leaves no element when nil" do
      with_caption =
        render_in_action(%{
          name: "Forgejo",
          in_action_intro: nil,
          screenshots: [shot(caption: "The repository list with search and filters")]
        })

      assert with_caption =~ "<figcaption"
      assert with_caption =~ "The repository list with search and filters"

      without_caption =
        render_in_action(%{name: "Forgejo", in_action_intro: nil, screenshots: [shot()]})

      refute without_caption =~ "<figcaption"
    end

    test "a nil intro omits the line — no generated fallback" do
      html = render_in_action(%{name: "Forgejo", in_action_intro: nil, screenshots: [shot()]})

      assert html =~ "Forgejo in action"
      refute html =~ "mt-4 text-lg"
    end
  end

  describe "features/1 (plan §6.4, S4)" do
    defp render_features(app) do
      render_component(&CatalogPageComponents.features/1, %{app: app})
    end

    test "nil and [] are the designed absent state — nothing renders, no gap" do
      for features <- [nil, []] do
        app = %{name: "Forgejo", features: features}
        html = render_features(app)

        assert String.trim(html) == ""
      end
    end

    test "four cards: eyebrow, h2, tile icons from the allowlist, titles, bodies" do
      features = [
        %{
          icon: "hero-archive-box",
          title: "Repositories",
          body: "Host your git repositories with mirrors and protected tags."
        },
        %{
          icon: "hero-arrow-path",
          title: "Pull requests",
          body: "Review changes line by line and merge them when ready."
        },
        %{
          icon: "hero-bolt",
          title: "Actions CI",
          body: "Run build workflows on every push with the built-in runner."
        },
        %{
          icon: "hero-user-group",
          title: "Issue tracking",
          body: "Track bugs and ideas with labels, milestones and assignees."
        }
      ]

      html = render_features(%{name: "Forgejo", features: features})

      assert html =~ ~s(data-testid="features-section")
      assert html =~ "Features"
      assert html =~ "What you can do with Forgejo"
      assert html =~ ~s(class="mt-10 grid gap-4 sm:grid-cols-2")
      assert length(Regex.scan(~r/data-testid="feature-card"/, html)) == 4

      # The icon rides the S1 allowlist name through <.icon>: one span
      # per card, no card is a link (no anchor, the plan's no-lift rule).
      for feature <- features do
        assert html =~ feature.icon
        assert html =~ feature.title
        assert html =~ feature.body
      end

      refute html =~ "<a"
    end
  end

  # #611 S6: the same components serve both surfaces, so every internal
  # link is caller-scoped. These pin the defaults (the public page) and
  # the authenticated overrides; the LiveView test pins the wiring.
  describe "caller-scoped navigation (S6)" do
    defp hero_app do
      %{
        slug: "forgejo",
        name: "Forgejo",
        description: nil,
        tagline: nil,
        caveats: nil,
        alternatives: nil,
        source_url: nil,
        docs_url: nil,
        community_url: nil,
        icon_url: nil,
        file_access: false,
        category: %{name: "Developer Tools", audience: nil}
      }
    end

    defp render_hero(overrides) do
      assigns =
        Map.merge(
          %{app: hero_app(), newest_version: nil, wake_estimates: %{}},
          Map.new(overrides)
        )

      render_component(&CatalogPageComponents.hero/1, assigns)
    end

    test "the hero's back link defaults to the public catalog" do
      html = render_hero([])

      assert html =~ ~s(href="/catalog")
      refute html =~ ~s(href="/apps")
    end

    test "the hero's back link follows back_path" do
      html = render_hero(back_path: "/apps")

      assert html =~ ~s(href="/apps")
      refute html =~ ~s(href="/catalog")
    end

    defp peers do
      [
        %{slug: "gitea", name: "Gitea", tagline: nil, icon_url: nil},
        %{slug: "gitlab", name: "GitLab", tagline: nil, icon_url: nil}
      ]
    end

    test "similar apps and the browse fallback default to the public detail path" do
      html =
        render_component(&CatalogPageComponents.similar_apps/1, %{
          peers: peers(),
          from_price_cents: nil
        })

      assert html =~ ~s(href="/catalog/gitea")
      assert html =~ ~s(href="/catalog/gitlab")

      fallback =
        render_component(&CatalogPageComponents.similar_apps/1, %{
          peers: [List.first(peers())],
          from_price_cents: nil
        })

      assert fallback =~ ~s(href="/catalog")
    end

    test "similar apps follow catalog_path on the authenticated surface" do
      html =
        render_component(&CatalogPageComponents.similar_apps/1, %{
          peers: peers(),
          from_price_cents: nil,
          catalog_path: "/apps"
        })

      assert html =~ ~s(href="/apps/gitea")
      assert html =~ ~s(href="/apps/gitlab")
      refute html =~ ~s(href="/catalog")

      fallback =
        render_component(&CatalogPageComponents.similar_apps/1, %{
          peers: [List.first(peers())],
          from_price_cents: nil,
          catalog_path: "/apps"
        })

      assert fallback =~ ~s(href="/apps")
    end

    test "the closing CTA's ghost button follows catalog_path" do
      public = render_component(&CatalogPageComponents.closing_cta/1, %{app: %{name: "Forgejo"}})
      assert public =~ ~s(href="/catalog")
      refute public =~ ~s(href="/apps")

      authed =
        render_component(&CatalogPageComponents.closing_cta/1, %{
          app: %{name: "Forgejo"},
          catalog_path: "/apps"
        })

      assert authed =~ ~s(href="/apps")
      refute authed =~ ~s(href="/catalog")
    end
  end
end
