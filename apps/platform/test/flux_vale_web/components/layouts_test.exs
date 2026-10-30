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

      assert classes["Instances"] =~ "text-ink"
      assert classes["Instances"] =~ "after:bg-primary"
      assert classes["Instances"] =~ "after:top-full"

      for label <- ["Catalog", "Billing"] do
        assert classes[label] =~ "text-ink-muted"
        assert classes[label] =~ "hover:bg-panel-raised"
        refute classes[label] =~ "after:"
      end
    end

    test "no section: every link stays quiet (sign-in posture, nil default)" do
      html = render_component(&ChromeProbe.with_section/1, [])
      doc = LazyHTML.from_fragment(html)

      classes = link_classes(doc)

      for label <- ["Catalog", "Instances", "Billing"] do
        class = Map.get(classes, label)

        assert class =~ "text-ink-muted", "#{label} should stay quiet"
        refute class =~ "after:bg-primary", "#{label} should carry no underline"
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
  end
end
