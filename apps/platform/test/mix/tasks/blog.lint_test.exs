defmodule Mix.Tasks.Blog.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import TestSupport.BlogFixtures

  alias Mix.Tasks.Blog.Lint

  describe "run/1" do
    test "valid content reports ok against the shipped directory" do
      assert capture_io(fn -> Lint.run([]) end) =~ "blog content ok"
    end

    test "invalid content prints every error and exits non-zero" do
      dir = post_dir(:task_fail)
      broken_path = Path.join(dir, "broken.md")
      File.write!(broken_path, "---\ntitle: Broken\n---\n\nBody\n")

      # Mix.Shell.IO.error writes to :stderr — capture it, not stdio.
      output =
        capture_io(:stderr, fn ->
          assert catch_exit(Lint.run([dir])) == {:shutdown, 1}
        end)

      assert output =~ "broken.md"
      assert output =~ ~s(missing required field "description")
      assert output =~ "mix blog.lint failed"
    end
  end
end
