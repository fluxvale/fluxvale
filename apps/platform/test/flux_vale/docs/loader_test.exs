defmodule FluxVale.Docs.LoaderTest do
  @moduledoc false

  # async: false — load!/1 publishes to :persistent_term, a global; the
  # fixture tests overwrite it and restore the real content on exit.

  use ExUnit.Case, async: false

  import TestSupport.DocsFixtures

  alias FluxVale.Docs
  alias FluxVale.Docs.Loader

  setup context do
    dir = content_dir(context.test)
    Loader.load!(dir)

    on_exit(fn -> Loader.load!() end)
    {:ok, dir: dir}
  end

  describe "load!/1" do
    test "compiles frontmatter into pages with the section from the directory", %{dir: dir} do
      write_page!(dir, "guides", "defaults-page", page_frontmatter("defaults-page"))

      :ok = Loader.load!(dir)
      [page] = Loader.loaded()

      assert page.title == "Page defaults-page"
      assert page.description == "A test page about defaults-page."
      assert page.order == 10
      assert page.slug == "defaults-page"
      assert page.section == "guides"
      assert page.source_path == Path.join(dir, "guides/defaults-page.md")
    end

    test "renders markdown once, with GFM extensions and no raw HTML", %{dir: dir} do
      body = """
      A paragraph with **bold** and a [link](https://fluxvale.com).

      | Col | Val |
      | --- | --- |
      | a   | 1   |

      <script>alert("no")</script>
      """

      write_page!(dir, "guides", "rendered-page", page_frontmatter("rendered-page"), body)

      :ok = Loader.load!(dir)
      [page] = Loader.loaded()

      assert page.html =~ "<strong>bold</strong>"
      assert page.html =~ ~s(<a href="https://fluxvale.com">link</a>)
      assert page.html =~ "<table>"
      # comrak's safe default: raw HTML in bodies never reaches the DOM.
      refute page.html =~ "<script>"
    end

    test "sorts by section order, then page order, then slug", %{dir: dir} do
      write_page!(dir, "help", "late-section", page_frontmatter("late-section"))

      second_base = page_frontmatter("b-second")
      second = List.replace_at(second_base, 2, "order: 20")
      write_page!(dir, "guides", "b-second", second)

      # Same order as a-first: the slug is the tie-break.
      tied_base = page_frontmatter("c-tied")
      tied = List.replace_at(tied_base, 2, "order: 10")
      write_page!(dir, "guides", "c-tied", tied)

      write_page!(dir, "guides", "a-first", page_frontmatter("a-first"))

      :ok = Loader.load!(dir)

      loaded = Loader.loaded()
      assert Enum.map(loaded, & &1.slug) == ["a-first", "c-tied", "b-second", "late-section"]
      assert Enum.map(loaded, & &1.section) == ["guides", "guides", "guides", "help"]
    end

    test "invalid content stops the load with the offending file named", %{dir: dir} do
      page_path = Path.join(dir, "guides/broken.md")

      page_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(page_path, "---\ntitle: Broken\n---\n\nBody\n")

      assert_raise ArgumentError,
                   ~r{guides/broken.md.*missing required field "description"}s,
                   fn ->
                     Loader.load!(dir)
                   end
    end

    test "a missing content root stops the load loudly (the sync never ran)", %{dir: dir} do
      missing = Path.join(dir, "absent")

      assert_raise ArgumentError,
                   ~r{docs content directory missing: .*absent.*mix content\.sync}s,
                   fn ->
                     Loader.load!(missing)
                   end
    end
  end

  describe "reload_if_changed!/1" do
    test "a clean tree is a no-op; a new file reloads", %{dir: dir} do
      write_page!(dir, "guides", "first-page", page_frontmatter("first-page"))
      :ok = Loader.load!(dir)

      assert :ok = Loader.reload_if_changed!(dir)
      assert Enum.map(Loader.loaded(), & &1.slug) == ["first-page"]

      write_page!(dir, "guides", "second-page", page_frontmatter("second-page"))

      assert :ok = Loader.reload_if_changed!(dir)
      assert Enum.map(Loader.loaded(), & &1.slug) == ["first-page", "second-page"]
    end
  end

  describe "FluxVale.Docs — the public seam" do
    test "all_pages/0, pages/1, get/2 over the loaded set", %{dir: dir} do
      write_page!(dir, "guides", "live-page", page_frontmatter("live-page"))
      write_page!(dir, "help", "live-faq", page_frontmatter("live-faq"))

      :ok = Loader.load!(dir)

      assert Enum.map(Docs.all_pages(), & &1.slug) == ["live-page", "live-faq"]

      guides_pages = Docs.pages("guides")
      assert Enum.map(guides_pages, & &1.slug) == ["live-page"]
      assert Docs.pages("automation") == []

      assert Docs.get("guides", "live-page").title == "Page live-page"
      assert Docs.get("guides", "absent") == nil
      assert Docs.get("absent", "live-page") == nil
    end

    test "sections_with_pages/0 drops empty sections", %{dir: dir} do
      write_page!(dir, "guides", "only-page", page_frontmatter("only-page"))

      :ok = Loader.load!(dir)

      sections = Docs.sections_with_pages()
      assert Enum.map(sections, fn {section, _pages} -> section.key end) == ["guides"]
      {section, pages} = hd(sections)
      assert section.title == "Guides"
      assert Enum.map(pages, & &1.slug) == ["only-page"]
    end

    test "maybe_hot_reload/0 recompiles when the tree changed and the flag is on" do
      # The stored stamp is this fixture dir's; the default (real) dir
      # differs, so the flagged call recompiles it. The env flag is
      # restored on exit — leaking it would flip the no-op test below.
      Application.put_env(:flux_vale, :docs_hot_reload, true)
      on_exit(fn -> Application.delete_env(:flux_vale, :docs_hot_reload) end)

      assert :ok = Docs.maybe_hot_reload()
      all_pages = Docs.all_pages()
      assert Enum.any?(all_pages, &(&1.slug == "first-app"))
    end

    test "maybe_hot_reload/0 is a no-op while the flag is unset" do
      assert :ok = Docs.maybe_hot_reload()
      # The fixture set is untouched — the flag short-circuits first.
      all_pages = Docs.all_pages()
      refute Enum.any?(all_pages, &(&1.slug == "first-app"))
    end
  end
end
