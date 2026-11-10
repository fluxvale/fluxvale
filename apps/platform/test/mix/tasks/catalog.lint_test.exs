defmodule Mix.Tasks.Catalog.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Catalog.Lint

  describe "run/1" do
    test "prints the shipped catalog's report and never fails (D1)" do
      output = capture_io(fn -> Lint.run([]) end)

      # S7 ships the full curated pass for every app.
      assert output =~ "forgejo: full parity"
      assert output =~ "docmost: full parity"
      assert output =~ "9 apps: 0 minimum, 0 recommended, 9 full parity"
    end
  end
end
