defmodule FluxValeWeb.Components.AdminShellTest do
  @moduledoc """
  The admin sidebar's contract (ADR-0027 Am. 4, #501): the workflow
  sections at their paths, the not-yet-built ones badged and linkless,
  deep debugging at its demoted subpaths, and the active entry marked
  aria-current. The #568 account-settings contract at admin scope.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.AdminShell

  # The sidebar's entries, in document order: key, href (nil for a
  # coming entry), active mark.
  defp entries(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid='admin-sidebar'] [data-testid^='admin-nav-']")
    |> Enum.map(fn node ->
      [testid] = LazyHTML.attribute(node, "data-testid")
      key = String.replace_prefix(testid, "admin-nav-", "")

      href =
        node
        |> LazyHTML.attribute("href")
        |> List.first()

      active = LazyHTML.attribute(node, "aria-current") == ["page"]

      {key, href, active}
    end)
  end

  # Every entry the sidebar carries, in order: the live sections, the
  # coming ones, then deep debugging.
  @entry_keys ~w(people catalog wallets feedback orgs gateways ash dashboard)
  @live_keys ~w(people catalog ash dashboard)
  @coming_keys ~w(wallets feedback orgs gateways)

  test "the sections in order, live ones at their paths, coming ones linkless" do
    html = render_component(&AdminShell.sidebar/1, current: "people")

    assert entries(html) == [
             {"people", "/admin/people", true},
             {"catalog", "/admin/catalog", false},
             {"wallets", nil, false},
             {"feedback", nil, false},
             {"orgs", nil, false},
             {"gateways", nil, false},
             {"ash", "/admin/ash", false},
             {"dashboard", "/admin/debug/dashboard", false}
           ]

    keys = entries(html)
    assert Enum.map(keys, &elem(&1, 0)) == @entry_keys
  end

  test "coming entries carry the Coming badge and nothing to follow" do
    html = render_component(&AdminShell.sidebar/1, current: "people")
    doc = LazyHTML.from_fragment(html)

    for key <- @coming_keys do
      badge_text =
        doc
        |> LazyHTML.query("[data-testid='admin-coming-#{key}']")
        |> LazyHTML.text()
        |> String.trim()

      assert badge_text == "Coming"

      # The honesty grammar: no href on the entry at all.
      nodes = LazyHTML.query(doc, "[data-testid='admin-nav-#{key}'][href]")

      assert Enum.to_list(nodes) == []
    end

    # Live entries all link.
    for key <- @live_keys do
      nodes = LazyHTML.query(doc, "[data-testid='admin-nav-#{key}'][href]")

      assert Enum.to_list(nodes) != []
    end
  end

  test "the live entries' labels read as the section names" do
    html = render_component(&AdminShell.sidebar/1, current: "people")
    doc = LazyHTML.from_fragment(html)

    labels = %{
      people: "People and invites",
      catalog: "Catalog and pricing",
      ash: "AshAdmin",
      dashboard: "LiveDashboard"
    }

    for {key, label} <- labels do
      label_text =
        doc
        |> LazyHTML.query("[data-testid='admin-nav-#{key}']")
        |> LazyHTML.text()
        |> String.trim()

      assert label_text == label
    end
  end

  test "the active entry flips with the surface" do
    html = render_component(&AdminShell.sidebar/1, current: "catalog")

    all = entries(html)

    active_marks = Enum.map(all, fn {key, _href, active} -> {key, active} end)

    assert active_marks == [
             {"people", false},
             {"catalog", true},
             {"wallets", false},
             {"feedback", false},
             {"orgs", false},
             {"gateways", false},
             {"ash", false},
             {"dashboard", false}
           ]
  end

  test "the deep debugging group carries its honest copy" do
    html = render_component(&AdminShell.sidebar/1, current: "people")

    copy =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid='admin-sidebar-copy-deep-debugging']")
      |> LazyHTML.text()
      |> String.trim()

    assert copy ==
             "The generated tools. They run as trusted superuser without the resource policies. For emergencies and data surgery."
  end

  test "the responsive contract rides the #568 idiom's classes" do
    # Stacked above the content below md, sticky rail from md up —
    # the account-settings sidebar's exact shape, pinned here so the
    # two sidebars cannot drift.
    html = render_component(&AdminShell.sidebar/1, current: "people")

    class =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid='admin-sidebar']")
      |> LazyHTML.attribute("class")
      |> List.first()

    for part <- ~w(flex flex-col md:sticky md:top-20 md:self-start) do
      assert class =~ part
    end

    aria =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid='admin-sidebar']")
      |> LazyHTML.attribute("aria-label")
      |> List.first()

    assert aria == "Admin"
  end
end
