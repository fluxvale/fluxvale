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
  alias FluxValeWeb.AdminConsole
  alias FluxValeWeb.AdminShell

  # The sidebar's entries, in document order: key, href (nil for a
  # coming entry), aria-current (nil when quiet). The console's
  # resource LEAVES (admin-nav-resource-*) are a separate grammar and
  # are excluded here — their own tests walk them.
  defp entries(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid^='admin-nav-']")
    |> Enum.reject(fn node ->
      [testid] = LazyHTML.attribute(node, "data-testid")
      String.starts_with?(testid, "admin-nav-resource-")
    end)
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
  # resource console's own group, then deep debugging.
  @entry_keys ~w(people catalog wallets feedback orgs storage-requests gateways audit health resources ash dashboard)

  test "the sections in order, live ones at their paths, coming ones linkless" do
    html = render_component(&AdminShell.sidebar/1, current: "people")

    assert entries(html) == [
             {"people", "/admin/people", "page"},
             {"catalog", "/admin/catalog", nil},
             {"wallets", "/admin/billing", nil},
             {"feedback", "/admin/moderation", nil},
             {"orgs", "/admin/orgs", nil},
             {"storage-requests", "/admin/storage-requests", nil},
             {"gateways", "/admin/gateways", nil},
             {"audit", "/admin/audit", nil},
             {"health", "/admin/health", nil},
             {"resources", "/admin/resources", nil},
             {"ash", "/admin/ash", nil},
             {"dashboard", "/admin/debug/dashboard", nil}
           ]

    keys = entries(html)
    assert Enum.map(keys, &elem(&1, 0)) == @entry_keys
  end

  test "the Coming grammar is retired: every section links, nothing is badged" do
    html = render_component(&AdminShell.sidebar/1, current: "people")
    doc = LazyHTML.from_fragment(html)

    # The completion flip (#608): all six sections live, zero Coming entries.
    # A path-less entry fails the render loudly rather than promising quietly.
    for key <- @entry_keys do
      nodes = LazyHTML.query(doc, "[data-testid='admin-nav-#{key}'][href]")

      assert Enum.to_list(nodes) != []
    end

    badge_nodes = LazyHTML.query(doc, "[data-testid^='admin-coming-']")
    assert Enum.to_list(badge_nodes) == []
    refute html =~ "Coming"
  end

  test "the live entries' labels read as the section names" do
    html = render_component(&AdminShell.sidebar/1, current: "people")
    doc = LazyHTML.from_fragment(html)

    labels = %{
      people: "People and invites",
      catalog: "Catalog and pricing",
      wallets: "Wallets and billing",
      feedback: "Feedback moderation",
      orgs: "Orgs and instances",
      "storage-requests": "Storage requests",
      gateways: "Access gateways and domains",
      audit: "Audit trail",
      health: "Health",
      resources: "Resource console",
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

  test "the storage-requests entry carries the pending count badge" do
    quiet = render_component(&AdminShell.sidebar/1, current: "people")
    refute has_badge?(quiet)

    html =
      render_component(&AdminShell.sidebar/1,
        current: "storage-requests",
        pending_requests: 3
      )

    doc = LazyHTML.from_fragment(html)

    badge =
      doc
      |> LazyHTML.query("[data-testid='admin-pending-storage-requests']")
      |> LazyHTML.text()
      |> String.trim()

    assert badge == "3"

    label =
      doc
      |> LazyHTML.query("[data-testid='admin-pending-storage-requests']")
      |> LazyHTML.attribute("aria-label")
      |> List.first()

    assert label == "3 pending storage requests"

    ordered = entries(html)

    assert Enum.at(ordered, 5) == {"storage-requests", "/admin/storage-requests", "page"}
  end

  defp has_badge?(html) do
    doc = LazyHTML.from_fragment(html)

    doc
    |> LazyHTML.query("[data-testid='admin-pending-storage-requests']")
    |> Enum.to_list() != []
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
             {"storage-requests", nil},
             {"gateways", nil},
             {"audit", nil},
             {"health", nil},
             {"resources", nil},
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

  test "the orgs entry flips live with the section's own contract" do
    # Same shape as the wallets flip: the org detail is a SUB-route of
    # the section (an ancestor mark), the section route is the page.
    sub = render_component(&AdminShell.sidebar/1, current: "orgs", exact: false)
    sub_entries = entries(sub)
    assert Enum.at(sub_entries, 4) == {"orgs", "/admin/orgs", "location"}

    exact = render_component(&AdminShell.sidebar/1, current: "orgs")
    exact_entries = entries(exact)

    assert Enum.at(exact_entries, 4) == {"orgs", "/admin/orgs", "page"}
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

  # -- D3 revised: the domain-divided Resources navigation ---------------

  # The console leaves, in registry order: {domain, resource, href}.
  defp leaves(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid^='admin-nav-resource-']")
    |> Enum.map(fn node ->
      [testid] = LazyHTML.attribute(node, "data-testid")
      leaf = String.trim_leading(testid, "admin-nav-resource-")
      [domain, resource] = String.split(leaf, "-", parts: 2)

      href =
        node
        |> LazyHTML.attribute("href")
        |> List.first()

      {domain, resource, href}
    end)
  end

  test "every live registry resource renders as a leaf linking its index" do
    html = render_component(&AdminShell.sidebar/1, current: "people")

    # The registry drives the nav: the leaf set IS the live registry's
    # (domain, resource) set, each leaf at its index href. Slices that
    # flip a domain live change the registry, and this walks with it.
    registry =
      for domain <- AdminConsole.domains(),
          resource <- domain.resources do
        {Atom.to_string(domain.key), Atom.to_string(resource.key),
         "/admin/resources/#{domain.key}/#{resource.key}"}
      end

    assert leaves(html) == registry
  end

  test "one collapsible group per live domain; pending domains render nothing" do
    html = render_component(&AdminShell.sidebar/1, current: "people")
    doc = LazyHTML.from_fragment(html)

    for domain <- AdminConsole.domains() do
      groups = LazyHTML.query(doc, "[data-testid='admin-sidebar-domain-#{domain.key}']")
      assert Enum.to_list(groups) != []
    end

    # The pending domains are not the nav's business until their slice:
    # no group, no leaves, nothing between them.
    for module <- AdminConsole.pending_domains() do
      split = Module.split(module)
      last = List.last(split)
      key = Macro.underscore(last)

      group_nodes = LazyHTML.query(doc, "[data-testid='admin-sidebar-domain-#{key}']")
      assert Enum.to_list(group_nodes) == []

      leaf_nodes = LazyHTML.query(doc, "[data-testid^='admin-nav-resource-#{key}-']")
      assert Enum.to_list(leaf_nodes) == []
    end
  end

  test "domain groups render collapsed everywhere except the active domain" do
    # No console state (every non-console surface, and the landing):
    # all groups collapsed — the plain <details>, no open attribute.
    collapsed = render_component(&AdminShell.sidebar/1, current: "people")
    collapsed_doc = LazyHTML.from_fragment(collapsed)
    collapsed_groups = LazyHTML.query(collapsed_doc, "details[open]")
    assert Enum.to_list(collapsed_groups) == []

    # A console surface names its active domain: that group renders
    # open (the `open` attribute alone — reloads and deep links render
    # the same shape), the others stay closed.
    open =
      render_component(&AdminShell.sidebar/1,
        current: "resources",
        exact: false,
        console: %{domain: :ops, resource: :feature_flag, exact: true}
      )

    open_doc = LazyHTML.from_fragment(open)

    opened =
      open_doc
      |> LazyHTML.query("details[open]")
      |> LazyHTML.attribute("data-testid")

    assert opened == ["admin-sidebar-domain-ops"]
  end

  test "the active leaf marks page or location; the landing entry stays quiet beneath it" do
    html =
      render_component(&AdminShell.sidebar/1,
        current: "resources",
        exact: false,
        console: %{domain: :ops, resource: :feature_flag, exact: true}
      )

    doc = LazyHTML.from_fragment(html)

    leaf_current =
      doc
      |> LazyHTML.query("[data-testid='admin-nav-resource-ops-feature_flag']")
      |> LazyHTML.attribute("aria-current")
      |> List.first()

    assert leaf_current == "page"

    landing_current =
      doc
      |> LazyHTML.query("[data-testid='admin-nav-resources']")
      |> LazyHTML.attribute("aria-current")
      |> List.first()

    # One marked entry per surface: the leaf is the position, the open
    # domain group is the ancestor signal — the landing entry goes
    # quiet beneath it.
    assert landing_current == nil

    sub_route =
      render_component(&AdminShell.sidebar/1,
        current: "resources",
        exact: false,
        console: %{domain: :ops, resource: :feature_flag, exact: false}
      )

    sub_doc = LazyHTML.from_fragment(sub_route)

    sub_current =
      sub_doc
      |> LazyHTML.query("[data-testid='admin-nav-resource-ops-feature_flag']")
      |> LazyHTML.attribute("aria-current")
      |> List.first()

    assert sub_current == "location"

    # A sibling leaf stays quiet.
    sibling =
      doc
      |> LazyHTML.query("[data-testid='admin-nav-resource-ops-access_rule']")
      |> LazyHTML.attribute("aria-current")
      |> List.first()

    assert sibling == nil
  end

  test "above the leaf level the landing entry keeps its own page/location grammar" do
    # The landing itself: no console state, the entry is the page.
    landing =
      render_component(&AdminShell.sidebar/1, current: "resources", exact: true)

    landing_current =
      landing
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid='admin-nav-resources']")
      |> LazyHTML.attribute("aria-current")
      |> List.first()

    assert landing_current == "page"

    # The domain page: no leaf yet, the landing entry is the ancestor.
    domain_page =
      render_component(&AdminShell.sidebar/1,
        current: "resources",
        exact: false,
        console: %{domain: :ops, resource: nil, exact: false}
      )

    domain_current =
      domain_page
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid='admin-nav-resources']")
      |> LazyHTML.attribute("aria-current")
      |> List.first()

    assert domain_current == "location"
  end
end
