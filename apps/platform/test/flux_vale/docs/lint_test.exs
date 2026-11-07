defmodule FluxVale.Docs.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import TestSupport.DocsFixtures

  alias FluxVale.Docs.Lint

  setup context do
    dir = content_dir(context.test)
    {:ok, dir: dir}
  end

  describe "check/1" do
    test "a valid directory passes", %{dir: dir} do
      write_page!(dir, "guides", "valid-page", page_frontmatter("valid-page"))

      assert :ok = Lint.check(dir)
    end

    test "a second known section passes", %{dir: dir} do
      write_page!(dir, "help", "valid-faq", page_frontmatter("valid-faq"))

      assert :ok = Lint.check(dir)
    end

    test "missing frontmatter is reported", %{dir: dir} do
      page_path = Path.join(dir, "guides/no-front.md")

      page_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(page_path, "Just a body, no frontmatter.\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "guides/no-front.md"
      assert error =~ "missing frontmatter"
    end

    test "an unterminated frontmatter block is reported", %{dir: dir} do
      page_path = Path.join(dir, "guides/unterminated.md")

      page_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(page_path, "---\ntitle: Dangling\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "closing ---"
    end

    test "invalid YAML is reported", %{dir: dir} do
      page_path = Path.join(dir, "guides/bad-yaml.md")

      page_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(page_path, "---\ntitle: [unclosed\n---\n\nBody\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "invalid YAML"
    end

    test "each missing required field is named", %{dir: dir} do
      page_path = Path.join(dir, "guides/sparse.md")

      page_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(page_path, "---\ntitle: Only a title\n---\n\nBody\n")

      assert {:error, errors} = Lint.check(dir)

      for field <- ["description", "order", "slug"] do
        assert Enum.any?(errors, &(&1 =~ "missing required field \"#{field}\""))
      end
    end

    test "a non-integer order is rejected", %{dir: dir} do
      ordered_base = page_frontmatter("ordered")
      ordered = List.replace_at(ordered_base, 2, "order: first")
      write_page!(dir, "guides", "ordered", ordered)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("order" must be an integer)
    end

    test "a non-string title is rejected", %{dir: dir} do
      typed_base = page_frontmatter("typed")
      typed = List.replace_at(typed_base, 0, "title: 42")
      write_page!(dir, "guides", "typed", typed)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ ~s("title" must be a string)
    end

    test "a slug that is not the filename stem is rejected", %{dir: dir} do
      write_page!(dir, "guides", "wrong-file", page_frontmatter("different-slug"))

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "must equal the filename stem"
    end

    test "a malformed slug is rejected", %{dir: dir} do
      write_page!(dir, "guides", "Bad_Slug", page_frontmatter("Bad_Slug"))

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "must be lowercase words joined by single hyphens"
    end

    test "unknown fields are rejected with the allowed list", %{dir: dir} do
      spicy = page_frontmatter("spicy", ["subtitle: Extra"])
      write_page!(dir, "guides", "spicy", spicy)

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "unknown field(s) subtitle"
      assert error =~ "allowed: title, description, order, slug"
    end

    test "every error names its file", %{dir: dir} do
      page_path = Path.join(dir, "guides/broken.md")

      page_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(page_path, "---\ntitle: Broken\n---\n\nBody\n")

      assert {:error, errors} = Lint.check(dir)
      assert Enum.all?(errors, &String.starts_with?(&1, "guides/broken.md:"))
    end
  end

  describe "check/1 boundary (ADR-0044 §6)" do
    test "a root-level markdown file is rejected", %{dir: dir} do
      stray_path = Path.join(dir, "index.md")
      File.write!(stray_path, "---\ntitle: Stray\n---\n\nBody\n")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "index.md"
      assert error =~ "known section"
    end

    test "an unknown section directory is rejected", %{dir: dir} do
      write_page!(dir, "pricing-notes", "secret", page_frontmatter("secret"))

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "pricing-notes/secret.md"
      assert error =~ "known section"
    end

    test "a nested directory inside a section is rejected", %{dir: dir} do
      write_page!(dir, "guides/sub", "nested", page_frontmatter("nested"))

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "guides/sub/nested.md"
    end

    test "a non-markdown file is rejected", %{dir: dir} do
      guides_dir = Path.join(dir, "guides")
      File.mkdir_p!(guides_dir)
      notes_path = Path.join(guides_dir, "notes.txt")
      File.write!(notes_path, "not a page")

      assert {:error, [error]} = Lint.check(dir)
      assert error =~ "guides/notes.txt"
    end
  end

  describe "file_paths/1" do
    test "lists only section markdown files, sorted, excluding boundary violations", %{dir: dir} do
      write_page!(dir, "guides", "b-page", page_frontmatter("b-page"))
      write_page!(dir, "guides", "a-page", page_frontmatter("a-page"))
      write_page!(dir, "help", "c-faq", page_frontmatter("c-faq"))
      # Boundary violations the check reports but file_paths skips.
      stray_path = Path.join(dir, "stray.md")
      File.write!(stray_path, "---\ntitle: Stray\n---\n\nBody\n")

      assert Lint.file_paths(dir) == [
               Path.join(dir, "guides/a-page.md"),
               Path.join(dir, "guides/b-page.md"),
               Path.join(dir, "help/c-faq.md")
             ]
    end
  end
end
