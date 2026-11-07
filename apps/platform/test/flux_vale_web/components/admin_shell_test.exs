defmodule FluxValeWeb.Components.AdminShellTest do
  @moduledoc """
  The admin sidebar's contract (ADR-0027 Am. 4, #501): the workflow
  sections at their paths, the not-yet-built ones badged and linkless,
  deep debugging at its demoted subpaths, and the active entry marked
  — "page" where the entry is the mounted page, "location" where it is
  the section ancestor. The #568 account-settings contract at admin
  scope, pinned CLASS-FOR-CLASS against the settings component so the
  two sidebars cannot drift apart.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.AccountSettings
  alias FluxValeWeb.AdminShell

  # The sidebar's entries, in document order: key, href (nil for a
  # coming entry), aria-current (nil when quiet).
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

      current =
        node
        |> LazyHTML.attribute("aria-current")
        |> List.first()

      {key, href, current}
    end)
  end

  # Every entry the sidebar carries, in order: the live sections, the
  # coming ones, then deep debugging.
  @entry_keys ~w(people catalog wallets feedback orgs gateways ash dashboard)
  @live_keys ~w(people catalog wallets ash dashboard)
  @coming_keys ~w(feedback orgs gateways)

  test "the sections in order, live ones at their paths, coming ones linkless" do
    html = render_component(&AdminShell.sidebar/1, current: "people")

    assert entries(html) == [
             {"people", "/admin/people", "page"},
             {"catalog", "/admin/catalog", nil},
             {"wallets", "/admin/billing", nil},
             {"feedback", nil, nil},
             {"orgs", nil, nil},
             {"gateways", nil, nil},
             {"ash", "/admin/ash", nil},
             {"dashboard", "/admin/debug/dashboard", nil}
           ]

    keys = entries(html)
    assert Enum.map(keys, &elem(&1, 0)) == @entry_keys
  end

  test "coming entries carry the Coming badge inline and nothing to follow" do
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

      # The badge rides inline after the label (the nav's width budget):
      # the entry is a label-plus-badge row, never a far-edge float.
      entry_class =
        doc
        |> LazyHTML.query("[data-testid='admin-nav-#{key}']")
        |> LazyHTML.attribute("class")
        |> List.first()

      assert entry_class =~ "items-center gap-2"
      refute entry_class =~ "justify-between"
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
      wallets: "Wallets and billing",
      ash: "AshAdmin",
      dashboard: "LiveDashboard"
    }

    for {key, label} <- labels do
      node = LazyHTML.query(doc, "[data-testid='admin-nav-#{key}']")
      text = LazyHTML.text(node)
      label_text = String.trim(text)

      assert label_text == label
    end
  end

  test "the active entry flips with the surface" do
    html = render_component(&AdminShell.sidebar/1, current: "catalog")
    all = entries(html)

    marks = Enum.map(all, fn {key, _href, current} -> {key, current} end)

    assert marks == [
             {"people", nil},
             {"catalog", "page"},
             {"wallets", nil},
             {"feedback", nil},
             {"orgs", nil},
             {"gateways", nil},
             {"ash", nil},
             {"dashboard", nil}
           ]
  end

  test "a sub-route marks its section entry as an ancestor, not the page" do
    # aria-current="page" is reserved for the entry whose href IS the
    # mounted page. The sizes ladder mounts the catalog section, not
    # the catalog entry's own href — the spec's ancestor mark is
    # "location".
    html = render_component(&AdminShell.sidebar/1, current: "catalog", exact: false)
    ancestors = entries(html)

    assert Enum.at(ancestors, 1) == {"catalog", "/admin/catalog", "location"}
    assert Enum.at(ancestors, 0) == {"people", "/admin/people", nil}

    # exact is the default: the section's own route marks "page".
    exact = render_component(&AdminShell.sidebar/1, current: "catalog")
    exact_entries = entries(exact)
    assert Enum.at(exact_entries, 1) == {"catalog", "/admin/catalog", "page"}
  end

  test "the wallets entry flips live with the section's own contract" do
    # The wallets detail is a SUB-route of the section: it marks the
    # entry an ancestor ("location"), never the page.
    sub = render_component(&AdminShell.sidebar/1, current: "wallets", exact: false)
    sub_entries = entries(sub)
    assert Enum.at(sub_entries, 2) == {"wallets", "/admin/billing", "location"}

    exact = render_component(&AdminShell.sidebar/1, current: "wallets")
    exact_entries = entries(exact)

    assert Enum.at(exact_entries, 2) == {"wallets", "/admin/billing", "page"}
  end

  test "an unknown section key raises — the keys are the entries of groups/0" do
    assert_raise ArgumentError, ~r/unknown admin section key "nope"/, fn ->
      render_component(&AdminShell.sidebar/1, current: "nope")
    end
  end

  test "the deep debugging group carries its honest copy, hidden below md" do
    html = render_component(&AdminShell.sidebar/1, current: "people")
    doc = LazyHTML.from_fragment(html)

    copy =
      doc
      |> LazyHTML.query("[data-testid='admin-sidebar-copy-deep-debugging']")
      |> LazyHTML.text()
      |> String.trim()

    assert copy ==
             "The generated tools. They run as trusted superuser without the resource policies. For emergencies and data surgery."

    # The narrow contract: the copy is context, not navigation — below
    # md it hides so the stacked nav never pushes the surfaces'
    # primary actions under the fold.
    copy_class =
      doc
      |> LazyHTML.query("[data-testid='admin-sidebar-copy-deep-debugging']")
      |> LazyHTML.attribute("class")
      |> List.first()

    assert copy_class =~ "hidden md:block"
  end

  test "the responsive contract rides the #568 idiom's classes" do
    # Stacked above the content below md, sticky rail from md up —
    # the account-settings sidebar's exact shape.
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

  # The drift pin, CLASS-FOR-CLASS against #568's own component: the
  # two sidebars must share the nav's layout classes, the group
  # label's register, and the active/quiet link treatment. Rendering
  # AccountSettings here means a class change there fails THIS test —
  # the admin sidebar moves with it (or the drift is a deliberate,
  # reviewed diff).
  test "class-for-class with the account-settings sidebar (#568)" do
    account =
      render_component(&AccountSettings.sidebar/1, current: "profile", personal_org_id: "org_1")

    admin = render_component(&AdminShell.sidebar/1, current: "people")

    account_doc = LazyHTML.from_fragment(account)
    admin_doc = LazyHTML.from_fragment(admin)

    nav_class = fn doc, testid ->
      doc
      |> LazyHTML.query("[data-testid='#{testid}']")
      |> LazyHTML.attribute("class")
      |> List.first()
    end

    assert nav_class.(admin_doc, "admin-sidebar") ==
             nav_class.(account_doc, "account-settings-sidebar")

    label_class = fn doc, testid ->
      doc
      |> LazyHTML.query("[data-testid='#{testid}'] p")
      |> LazyHTML.attribute("class")
      |> List.first()
    end

    assert label_class.(admin_doc, "admin-sidebar-group-sections") ==
             label_class.(account_doc, "account-settings-section-account")

    link_class = fn doc, testid ->
      doc
      |> LazyHTML.query("[data-testid='#{testid}']")
      |> LazyHTML.attribute("class")
      |> List.first()
    end

    assert link_class.(admin_doc, "admin-nav-people") ==
             link_class.(account_doc, "account-settings-nav-profile")

    assert link_class.(admin_doc, "admin-nav-catalog") ==
             link_class.(account_doc, "account-settings-nav-access")
  end
end
