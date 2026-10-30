defmodule FluxVale.Blog.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import TestSupport.BlogFixtures

  alias FluxVale.Blog.Lint

  setup context do
    dir = post_dir(context.test)
    {:ok, dir: dir}
  end

  describe "check/1" do
    test "a valid directory passes", %{dir: dir} do
      frontmatter = post_frontmatter("valid-post", ["draft: false"])
      write_post!(dir, "valid-post", frontmatter)

      assert :ok = Lint.check(dir)
    end

    test "optional fields accept their types", %{dir: dir} do
      full_frontmatter = [
        "title: Full",
        "description: Every optional field.",
        "date: 2026-10-31",
        "slug: full-post",
        "author: Tester",
        "draft: true",
        "og_image: /images/mark.svg",
        "tags:",
        "  - one",
        "  - two"
      ]

      write_post!(dir, "full-post", full_frontmatter)

      assert :ok = Lint.check(dir)
    end

    test "missing frontmatter is reported", %{dir: dir} do
      write_post!(dir, "no-front", [])
      no_front_md_path = Path.join(dir, "no-front.md")
      File.write!(no_front_md_path, "Just a body, no frontmatter.\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "no-front.md"
      assert error =~ "missing frontmatter"
    end

    test "an unterminated frontmatter block is reported", %{dir: dir} do
      unterminated_md_path = Path.join(dir, "unterminated.md")
      File.write!(unterminated_md_path, "---\ntitle: Dangling\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "closing ---"
    end

    test "invalid YAML is reported", %{dir: dir} do
      bad_yaml_md_path = Path.join(dir, "bad-yaml.md")
      File.write!(bad_yaml_md_path, "---\ntitle: [unclosed\n---\n\nBody\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "invalid YAML"
    end

    test "each missing required field is named", %{dir: dir} do
      sparse_md_path = Path.join(dir, "sparse.md")
      File.write!(sparse_md_path, "---\ntitle: Only a title\n---\n\nBody\n")

      assert {:error, errors} = Lint.check(dir)

      for field <- ["description", "date", "slug", "author"] do
        assert Enum.any?(errors, &(&1 =~ "missing required field \"#{field}\""))
      end
    end

    test "a non-string date is rejected", %{dir: dir} do
      dated_base = post_frontmatter("dated")
      dated = List.replace_at(dated_base, 2, "date: [2026, 10, 31]")
      write_post!(dir, "dated", dated)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("date" must be a YYYY-MM-DD date)
    end

    test "a non-string slug is rejected", %{dir: dir} do
      slugged_base = post_frontmatter("slugged")
      slugged = List.replace_at(slugged_base, 3, "slug: [slugged]")
      write_post!(dir, "slugged", slugged)

      # Both the string-field rule and the slug rule name it.
      assert {:error, errors} = Lint.check(dir)
      assert Enum.any?(errors, &(&1 =~ ~s("slug" must be a string)))
    end

    test "a non-string og_image is rejected", %{dir: dir} do
      ogged = post_frontmatter("ogged", ["og_image: 42"])
      write_post!(dir, "ogged", ogged)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("og_image" must be a string)
    end

    test "a non-list tags field is rejected", %{dir: dir} do
      tagged = post_frontmatter("tagged", ["tags: alpha"])
      write_post!(dir, "tagged", tagged)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("tags" must be a list of strings)
    end

    test "non-mapping frontmatter is rejected", %{dir: dir} do
      scalar_path = Path.join(dir, "scalar.md")
      File.write!(scalar_path, "---\n7\n---\n\nBody\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "frontmatter must be a YAML mapping"
    end

    test "a non-string title is rejected", %{dir: dir} do
      typed_frontmatter = [
        "title: 42",
        "description: Numbers are not titles.",
        "date: 2026-10-31",
        "slug: typed",
        "author: Tester"
      ]

      write_post!(dir, "typed", typed_frontmatter)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("title" must be a string)
    end

    test "a malformed date is rejected", %{dir: dir} do
      dated_base = post_frontmatter("dated")
      dated = List.replace_at(dated_base, 2, "date: Oct 31")
      write_post!(dir, "dated", dated)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("date" must be a YYYY-MM-DD date)
    end

    test "a slug that is not the filename stem is rejected", %{dir: dir} do
      frontmatter = post_frontmatter("different-slug")
      write_post!(dir, "wrong-file", frontmatter)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s(must equal the filename stem)
    end

    test "a malformed slug is rejected", %{dir: dir} do
      frontmatter = post_frontmatter("Bad_Slug")
      write_post!(dir, "Bad_Slug", frontmatter)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s(must be lowercase words joined by single hyphens)
    end

    test "duplicate slugs fail the stem rule (no cross-file rule needed)", %{dir: dir} do
      one_frontmatter = post_frontmatter("clash")
      write_post!(dir, "one", one_frontmatter)

      two_frontmatter = post_frontmatter("clash")
      write_post!(dir, "two", two_frontmatter)

      assert {:error, errors} = Lint.check(dir)
      assert length(errors) == 2
      assert Enum.all?(errors, &(&1 =~ "must equal the filename stem"))
    end

    test "a non-boolean draft is rejected", %{dir: dir} do
      drafty = post_frontmatter("drafty", ["draft: yes-please"])
      write_post!(dir, "drafty", drafty)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("draft" must be a boolean)
    end

    test "a non-absolute og_image is rejected", %{dir: dir} do
      absolute_og = post_frontmatter("oggy", ["og_image: https://cdn.example.com/x.png"])
      write_post!(dir, "oggy", absolute_og)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("og_image" must be an app-absolute path)
    end

    test "an og_image that ships nowhere is rejected", %{dir: dir} do
      missing_og = post_frontmatter("oggy", ["og_image: /images/does-not-exist.png"])
      write_post!(dir, "oggy", missing_og)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("og_image" does not resolve to a shipped static file)
    end

    test "non-string tags are rejected", %{dir: dir} do
      tagged = post_frontmatter("tagged", ["tags:", "  - 1", "  - 2"])
      write_post!(dir, "tagged", tagged)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("tags" must be a list of strings)
    end

    test "unknown fields are rejected with the allowed list", %{dir: dir} do
      spicy = post_frontmatter("spicy", ["subtitle: Extra"])
      write_post!(dir, "spicy", spicy)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "unknown field(s) subtitle"
      assert error =~ "allowed: title, description, date, slug, author, draft, og_image, tags"
    end

    test "every error names its file", %{dir: dir} do
      broken_md_path = Path.join(dir, "broken.md")
      File.write!(broken_md_path, "---\ntitle: Broken\n---\n\nBody\n")

      assert {:error, errors} = Lint.check(dir)
      assert Enum.all?(errors, &String.starts_with?(&1, "broken.md:"))
    end
  end

  describe "parse/1" do
    test "splits frontmatter from the markdown body", %{dir: dir} do
      write_post!(dir, "parsed", post_frontmatter("parsed"), "The **body**.\n")

      parsed_path = Path.join(dir, "parsed.md")
      assert {:ok, attrs, body} = Lint.parse(parsed_path)
      assert attrs["title"] == "Post parsed"
      assert attrs["slug"] == "parsed"
      assert body =~ "The **body**."
    end
  end

  describe "file_paths/1" do
    test "lists only markdown files, sorted", %{dir: dir} do
      b_frontmatter = post_frontmatter("b-post")
      write_post!(dir, "b-post", b_frontmatter)

      a_frontmatter = post_frontmatter("a-post")
      write_post!(dir, "a-post", a_frontmatter)
      notes_txt_path = Path.join(dir, "notes.txt")
      File.write!(notes_txt_path, "not a post")

      first_path = Path.join(dir, "a-post.md")
      second_path = Path.join(dir, "b-post.md")
      assert Lint.file_paths(dir) == [first_path, second_path]
    end
  end
end
