defmodule FluxValeWeb.Components.LayoutsTest do
  @moduledoc """
  The chrome contracts the app-wide grammar lane adds: `bare` flips main
  unbounded for band-capable pages while the default stays byte-identical,
  and `nav_section` (assigned by NavSection's on_mount, passed through by
  callers like every chrome assign) marks exactly its section's link —
  the header's round-3 amber underline for catalog/instances, the user
  menu's Billing row for billing (#467).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxVale.TestSupport.ChromeProbe

  defp main_class(opts) do
    html = render_component(&ChromeProbe.with_section/1, opts)

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("main")
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  # The header row's own measure (#593): `wide` is the console lane's
  # half of the flush layout — main's bounded/unbounded split has its
  # pair below, this is the header's.
  defp header_row_class(opts) do
    html = render_component(&ChromeProbe.with_section/1, opts)

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("header > div")
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  describe "bare main" do
    test "default: main keeps the bounded chrome class list, byte-identical" do
      assert main_class([]) == "mx-auto w-full max-w-5xl flex-1 px-4 py-10 sm:px-6 lg:px-8"
    end

    test "bare: main renders unbounded — no max-width, no padding" do
      assert main_class(bare: true) == "flex-1"
    end
  end

  describe "wide header row (#593)" do
    test "default: the header row keeps the centered measure, byte-identical" do
      assert header_row_class([]) ==
               "mx-auto flex h-14 max-w-5xl items-center justify-between gap-4 px-4 sm:px-6 lg:px-8"
    end

    # The gutter tokens are load-bearing: the console's own wraps sit
    # on the same px-4 sm:px-6 lg:px-8 (app_grammar.css's .wrap
    # padding-inline), so the logo anchors above the sidebar. A drift
    # here re-opens the defect #593 fixed with a green suite.
    test "wide: the header row spans the viewport at the wrap gutter — no centering, no measure" do
      assert header_row_class(wide: true) ==
               "flex h-14 items-center justify-between gap-4 px-4 sm:px-6 lg:px-8"
    end
  end

  describe "nav_section" do
    test "it marks exactly its section's link" do
      html = render_component(&ChromeProbe.with_section/1, nav_section: :instances)
      doc = LazyHTML.from_fragment(html)

      classes = link_classes(doc)

      # Exact token, not a substring: "text-ink" also lives inside
      # "text-ink-muted", which would make the positive assert unfaillable.
      assert "text-ink" in String.split(classes["Instances"], " ")
      assert classes["Instances"] =~ "after:bg-focus"
      assert classes["Instances"] =~ "after:top-full"

      for label <- ["Catalog", "Feedback"] do
        assert classes[label] =~ "text-ink-muted"
        assert classes[label] =~ "hover:bg-panel-raised"
        refute classes[label] =~ "after:"
      end
    end

    # #467: Billing left the header row for the account menu, so no
    # header link marks for :billing — the menu's Billing row is the
    # section's only link and carries the mark itself.
    test "the billing section marks the menu row, never a header link" do
      html = render_component(&ChromeProbe.signed_in/1, nav_section: :billing)
      doc = LazyHTML.from_fragment(html)

      current = aria_current(doc, "nav[aria-label='Primary'] > ul > li > a")

      for label <- ["Catalog", "Instances", "Feedback"] do
        assert Map.get(current, label) == nil
      end

      rows = aria_current(doc, "[data-testid='user-menu-panel'] a")
      assert rows["Billing"] == "page"
      assert rows["Account settings"] == nil

      # The menu idiom (#319): ink + bold, never the header's underline.
      classes = menu_row_classes(doc)
      assert classes["Billing"] =~ "font-semibold"
      assert "text-ink" in String.split(classes["Billing"], " ")
      refute classes["Billing"] =~ "after:"
    end

    test "the section's folded menu row carries the active treatment" do
      html = render_component(&ChromeProbe.signed_in/1, nav_section: :instances)
      doc = LazyHTML.from_fragment(html)

      rows = menu_row_classes(doc)

      # The menu idiom: ink + bold, never the header's hanging underline.
      assert rows["Instances"] =~ "font-semibold"
      # Exact token, not a substring (text-ink ⊂ text-ink-muted).
      assert "text-ink" in String.split(rows["Instances"], " ")
      refute rows["Instances"] =~ "after:bg-focus"

      for label <- ["Catalog", "Billing"] do
        assert rows[label] =~ "text-ink-muted", "#{label} should stay quiet"
        refute rows[label] =~ "font-semibold", "#{label} should not bold"
      end
    end

    test "the folded menu row's active state is exposed as aria-current too" do
      html = render_component(&ChromeProbe.signed_in/1, nav_section: :catalog)
      doc = LazyHTML.from_fragment(html)

      current = aria_current(doc, "[data-testid='user-menu-panel'] a")

      assert current["Catalog"] == "page"
      assert current["Instances"] == nil
      assert current["Billing"] == nil
    end

    test "no section: every link stays quiet (sign-in posture, nil default)" do
      html = render_component(&ChromeProbe.with_section/1, [])
      doc = LazyHTML.from_fragment(html)

      classes = link_classes(doc)

      for label <- ["Catalog", "Instances", "Feedback"] do
        class = Map.get(classes, label)

        assert class =~ "text-ink-muted", "#{label} should stay quiet"
        refute class =~ "after:bg-focus", "#{label} should carry no underline"

        current =
          aria_current(doc, "nav[aria-label='Primary'] > ul > li > a")

        assert Map.get(current, label) == nil
      end
    end

    # #467/#551: the signed-in nav row renders exactly Catalog,
    # Instances, Feedback — Billing moved to the account menu, Pricing
    # left the chrome entirely (the menu row retired with #551).
    test "the signed-in header row renders exactly Catalog, Instances, Feedback" do
      html = render_component(&ChromeProbe.signed_in/1, [])
      doc = LazyHTML.from_fragment(html)

      labels = header_labels(doc)

      assert labels == ["Catalog", "Instances", "Feedback"]
    end

    # #467: Billing rides the account menu at every width, listed with
    # the account entries — the row never folds (it has no header copy
    # to double below sm anymore).
    test "Billing rides the account menu at every width" do
      html = render_component(&ChromeProbe.signed_in/1, [])
      doc = LazyHTML.from_fragment(html)

      rows = menu_row_classes(doc)
      assert rows["Billing"] =~ "text-ink-muted"
      refute rows["Billing"] =~ "sm:hidden"
    end

    # #551: Pricing and About left the account menu. The pages stay
    # public — /pricing rides the public chrome's header and footer,
    # /about is the landing — only the menu rows are gone.
    test "the menu carries no Pricing and no About FluxVale (#551)" do
      html = render_component(&ChromeProbe.signed_in/1, [])
      doc = LazyHTML.from_fragment(html)

      rows = menu_row_classes(doc)

      refute Map.has_key?(rows, "Pricing")
      refute Map.has_key?(rows, "About FluxVale")
    end

    # #551: the Admin row rides only for a platform admin — the chrome
    # feeds FluxVale.Checks.ActorIsPlatformAdmin, the same predicate the
    # admin door's plug and on_mount answer. A member or a role-less
    # map renders no row at all: the link never exists to click.
    test "the Admin row renders only for a platform admin, at /admin (#551)" do
      admin_html = render_component(&ChromeProbe.signed_in/1, platform_role: :admin)
      doc = LazyHTML.from_fragment(admin_html)

      assert menu_labels(doc) == [
               "Catalog",
               "Instances",
               "Feedback",
               "Billing",
               "Account settings",
               "Admin"
             ]

      admin_link =
        doc
        |> LazyHTML.query("[data-testid='user-menu-admin']")
        |> Enum.at(0)

      assert LazyHTML.attribute(admin_link, "href") == ["/admin"]

      for role <- [nil, :user] do
        html = render_component(&ChromeProbe.signed_in/1, platform_role: role)
        non_admin = LazyHTML.from_fragment(html)
        labels = menu_labels(non_admin)

        refute Enum.member?(labels, "Admin")

        assert non_admin
               |> LazyHTML.query("[data-testid='user-menu-admin']")
               |> Enum.to_list() == []
      end
    end

    # #255's fold is per-row: each mirror of a below-sm-hidden header
    # link carries sm:hidden, so no width shows both copies.
    test "the fold rows gate below sm" do
      html = render_component(&ChromeProbe.signed_in/1, [])
      doc = LazyHTML.from_fragment(html)

      rows = menu_row_classes(doc)

      for label <- ["Catalog", "Instances", "Feedback"] do
        assert rows[label] =~ "sm:hidden", "#{label} should fold below sm"
      end
    end

    # #255's fold survives the reshuffle: Catalog/Instances/Feedback
    # mirror the below-sm-hidden header links, then the every-width
    # rows and the account entries. #551: Pricing and About are gone,
    # so the account entries end the list. The panel carries Sign out.
    test "the dropdown reads surface fold, then the account entries" do
      html = render_component(&ChromeProbe.signed_in/1, [])
      doc = LazyHTML.from_fragment(html)

      assert menu_labels(doc) == [
               "Catalog",
               "Instances",
               "Feedback",
               "Billing",
               "Account settings"
             ]

      panel_text =
        doc
        |> LazyHTML.query("[data-testid='user-menu-panel']")
        |> LazyHTML.text()

      assert panel_text =~ "Sign out"
    end

    defp link_classes(doc) do
      doc
      # The header's own links: the user menu's folded rows hang deeper
      # inside this nav (li > details), so the selector stays shallow.
      |> LazyHTML.query("nav[aria-label='Primary'] > ul > li > a")
      |> Map.new(fn link ->
        text =
          link
          |> LazyHTML.text()
          |> String.trim()

        class =
          link
          |> LazyHTML.attribute("class")
          |> List.first()

        {text, class}
      end)
    end

    defp aria_current(doc, selector) do
      doc
      |> LazyHTML.query(selector)
      |> Map.new(fn link ->
        text =
          link
          |> LazyHTML.text()
          |> String.trim()

        current =
          link
          |> LazyHTML.attribute("aria-current")
          |> List.first()

        {text, current}
      end)
    end

    # The header's own links, in document order — the user menu's rows
    # hang deeper inside this nav (li > details), so the selector stays
    # shallow and sees the row, not the menu.
    defp header_labels(doc) do
      doc
      |> LazyHTML.query("nav[aria-label='Primary'] > ul > li > a")
      |> Enum.map(&row_text/1)
    end

    # The user menu's panel rows, in document order.
    defp menu_labels(doc) do
      doc
      |> LazyHTML.query("[data-testid='user-menu-panel'] a")
      |> Enum.map(&row_text/1)
    end

    defp row_text(link) do
      link
      |> LazyHTML.text()
      |> String.trim()
    end

    # The user menu's panel rows (the below-sm folded set among them).
    defp menu_row_classes(doc) do
      doc
      |> LazyHTML.query("[data-testid='user-menu-panel'] a")
      |> Map.new(fn link ->
        text =
          link
          |> LazyHTML.text()
          |> String.trim()

        class =
          link
          |> LazyHTML.attribute("class")
          |> List.first()

        {text, class}
      end)
    end
  end
end
