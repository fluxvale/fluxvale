defmodule Mix.Tasks.Docs.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import TestSupport.DocsFixtures

  alias Mix.Tasks.Docs.Lint

  describe "run/1" do
    test "valid content reports ok against the shipped source tree" do
      assert capture_io(fn -> Lint.run([]) end) =~ "docs content ok"
    end

    test "invalid content prints every error and exits non-zero" do
      dir = content_dir(:task_fail)
      page_path = Path.join(dir, "guides/broken.md")

      page_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(page_path, "---\ntitle: Broken\n---\n\nBody\n")

      # Mix.Shell.IO.error writes to :stderr — capture it, not stdio.
      output =
        capture_io(:stderr, fn ->
          assert catch_exit(Lint.run([dir])) == {:shutdown, 1}
        end)

      assert output =~ "guides/broken.md"
      assert output =~ ~s(missing required field "description")
      assert output =~ "mix docs.lint failed"
    end
  end
end
