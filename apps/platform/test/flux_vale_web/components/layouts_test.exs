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

  describe "bare main" do
    test "default: main keeps the bounded chrome class list, byte-identical" do
      assert main_class([]) == "mx-auto w-full max-w-5xl flex-1 px-4 py-10 sm:px-6 lg:px-8"
    end

    test "bare: main renders unbounded — no max-width, no padding" do
      assert main_class(bare: true) == "flex-1"
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

    # #467: the signed-in nav row renders exactly Catalog, Instances,
    # Feedback — Billing moved to the account menu, Pricing left the
    # row for the menu's every-width row.
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

    # #467: Pricing keeps a menu row so /pricing stays reachable — the
    # app chrome has no footer, so below sm no longer gates it.
    test "the menu carries Pricing at every width" do
      html = render_component(&ChromeProbe.signed_in/1, [])
      doc = LazyHTML.from_fragment(html)

      rows = menu_row_classes(doc)
      assert rows["Pricing"] =~ "text-ink-muted"
      refute rows["Pricing"] =~ "sm:hidden"
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
    # rows and the account entries. The panel text carries Sign out.
    test "the dropdown reads surface fold, then Pricing, then account entries" do
      html = render_component(&ChromeProbe.signed_in/1, [])
      doc = LazyHTML.from_fragment(html)

      assert menu_labels(doc) == [
               "Catalog",
               "Instances",
               "Feedback",
               "Pricing",
               "Billing",
               "Account settings",
               "About FluxVale"
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
