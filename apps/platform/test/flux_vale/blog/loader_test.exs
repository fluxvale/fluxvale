defmodule FluxVale.Blog.LoaderTest do
  @moduledoc false

  # async: false — load!/1 publishes to :persistent_term, a global; the
  # fixture tests overwrite it and restore the real content on exit.

  use ExUnit.Case, async: false

  import TestSupport.BlogFixtures

  alias FluxVale.Blog
  alias FluxVale.Blog.Loader

  setup context do
    dir = post_dir(context.test)
    Loader.load!(dir)

    on_exit(fn -> Loader.load!() end)
    {:ok, dir: dir}
  end

  describe "load!/1" do
    test "compiles frontmatter into posts with defaults", %{dir: dir} do
      write_post!(dir, "defaults-post", post_frontmatter("defaults-post"))

      :ok = Loader.load!(dir)
      [post] = Loader.loaded()

      assert post.title == "Post defaults-post"
      assert post.description == "A test post about defaults-post."
      assert post.date == ~D[2026-10-31]
      assert post.author == "Tester"
      # Optional frontmatter defaults: published, no override, no tags.
      assert post.draft == false
      assert post.og_image == nil
      assert post.tags == []
      assert post.source_path == Path.join(dir, "defaults-post.md")
    end

    test "optional fields ride through", %{dir: dir} do
      options_frontmatter = [
        "title: Options",
        "description: With every option.",
        "date: 2026-10-31",
        "slug: options-post",
        "author: Tester",
        "draft: true",
        "tags:",
        "  - alpha"
      ]

      write_post!(dir, "options-post", options_frontmatter)

      :ok = Loader.load!(dir)
      [post] = Loader.loaded()

      assert post.draft == true
      assert post.tags == ["alpha"]
    end

    test "renders markdown once, with GFM extensions and no raw HTML", %{dir: dir} do
      body = """
      A paragraph with **bold** and a [link](https://fluxvale.com).

      | Col | Val |
      | --- | --- |
      | a   | 1   |

      ~~/hidden/~~

      <script>alert("no")</script>
      """

      write_post!(dir, "rendered-post", post_frontmatter("rendered-post"), body)

      :ok = Loader.load!(dir)
      [post] = Loader.loaded()

      assert post.html =~ "<strong>bold</strong>"
      assert post.html =~ ~s(<a href="https://fluxvale.com">link</a>)
      assert post.html =~ "<table>"
      assert post.html =~ "<del>/hidden/</del>"
      # comrak's safe default: raw HTML in bodies never reaches the DOM.
      refute post.html =~ "<script>"
    end

    test "sorts newest first", %{dir: dir} do
      older_base = post_frontmatter("older-post")
      older = List.replace_at(older_base, 2, "date: 2026-01-01")
      write_post!(dir, "older-post", older)

      newer_base = post_frontmatter("newer-post")
      newer = List.replace_at(newer_base, 2, "date: 2026-06-01")
      write_post!(dir, "newer-post", newer)

      :ok = Loader.load!(dir)
      loaded = Loader.loaded()
      assert Enum.map(loaded, & &1.slug) == ["newer-post", "older-post"]
    end

    test "reading minutes: short posts floor at one, long posts scale", %{dir: dir} do
      short =
        ~w(word)
        |> List.duplicate(50)
        |> Enum.join(" ")

      long =
        ~w(word)
        |> List.duplicate(450)
        |> Enum.join(" ")

      write_post!(dir, "short-post", post_frontmatter("short-post"), short)
      write_post!(dir, "long-post", post_frontmatter("long-post"), long)

      :ok = Loader.load!(dir)
      loaded = Loader.loaded()
      minutes = Map.new(loaded, &{&1.slug, &1.reading_minutes})

      assert minutes["short-post"] == 1
      assert minutes["long-post"] == 3
    end

    test "invalid content stops the load with the offending file named", %{dir: dir} do
      broken_path = Path.join(dir, "broken.md")
      File.write!(broken_path, "---\ntitle: Broken\n---\n\nBody\n")

      assert_raise ArgumentError, ~r/broken.md.*missing required field "description"/s, fn ->
        Loader.load!(dir)
      end
    end
  end

  describe "reload_if_changed!/1" do
    test "a clean tree is a no-op; a new file reloads", %{dir: dir} do
      write_post!(dir, "first-post", post_frontmatter("first-post"))
      :ok = Loader.load!(dir)

      assert :ok = Loader.reload_if_changed!(dir)
      loaded = Loader.loaded()
      assert Enum.map(loaded, & &1.slug) == ["first-post"]

      # A NEWER date: the reloaded set must still read newest-first.
      second_base = post_frontmatter("second-post")
      second = List.replace_at(second_base, 2, "date: 2026-12-01")
      write_post!(dir, "second-post", second)

      assert :ok = Loader.reload_if_changed!(dir)
      assert Enum.map(Loader.loaded(), & &1.slug) == ["second-post", "first-post"]
    end
  end

  describe "FluxVale.Blog — the public seam" do
    test "all/0, published/0, get/1 over the loaded set", %{dir: dir} do
      write_post!(dir, "live-post", post_frontmatter("live-post"))
      write_post!(dir, "hidden-post", post_frontmatter("hidden-post", ["draft: true"]))

      :ok = Loader.load!(dir)

      all = Blog.all()
      assert Enum.map(all, & &1.slug) == ["hidden-post", "live-post"]

      published = Blog.published()
      assert Enum.map(published, & &1.slug) == ["live-post"]

      assert Blog.get("live-post").title == "Post live-post"
      assert Blog.get("hidden-post").draft == true
      assert Blog.get("absent") == nil
    end

    test "maybe_hot_reload/0 recompiles when the tree changed and the flag is on" do
      # The stored stamp is this fixture dir's; the default (real) dir
      # differs, so the flagged call recompiles it. The env flag is
      # restored on exit — leaking it would flip the no-op test below.
      Application.put_env(:flux_vale, :blog_hot_reload, true)
      on_exit(fn -> Application.delete_env(:flux_vale, :blog_hot_reload) end)

      assert :ok = Blog.maybe_hot_reload()
      all = Blog.all()
      assert Enum.any?(all, &(&1.slug == "example-post"))
    end

    test "maybe_hot_reload/0 is a no-op while the flag is unset" do
      assert :ok = Blog.maybe_hot_reload()
      # The fixture set is untouched — the flag short-circuits first.
      all = Blog.all()
      refute Enum.any?(all, &(&1.slug == "example-post"))
    end
  end
end
