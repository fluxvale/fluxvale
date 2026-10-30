defmodule FluxValeWeb.Components.LayoutsTest do
  @moduledoc """
  The chrome contracts the app-wide grammar lane adds: `bare` flips main
  unbounded for band-capable pages while the default stays byte-identical,
  and `nav_section` (assigned by NavSection's on_mount, passed through by
  callers like every chrome assign) marks exactly its section's header
  link with the round-3 amber underline.
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

      for label <- ["Catalog", "Billing"] do
        assert classes[label] =~ "text-ink-muted"
        assert classes[label] =~ "hover:bg-panel-raised"
        refute classes[label] =~ "after:"
      end
    end

    test "the active link is exposed to assistive tech as aria-current" do
      html = render_component(&ChromeProbe.with_section/1, nav_section: :billing)
      doc = LazyHTML.from_fragment(html)

      current = aria_current(doc, "nav[aria-label='Primary'] > ul > li > a")

      assert current["Billing"] == "page"
      assert current["Catalog"] == nil
      assert current["Instances"] == nil
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

      for label <- ["Catalog", "Instances", "Billing"] do
        class = Map.get(classes, label)

        assert class =~ "text-ink-muted", "#{label} should stay quiet"
        refute class =~ "after:bg-focus", "#{label} should carry no underline"

        current =
          aria_current(doc, "nav[aria-label='Primary'] > ul > li > a")

        assert Map.get(current, label) == nil
      end
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
