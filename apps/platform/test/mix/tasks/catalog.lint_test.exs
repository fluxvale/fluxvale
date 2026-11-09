defmodule Mix.Tasks.Catalog.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Catalog.Lint

  describe "run/1" do
    test "prints the shipped catalog's report and never fails (D1)" do
      output = capture_io(fn -> Lint.run([]) end)

      assert output =~ "forgejo: recommended"
      assert output =~ "docmost: recommended"
      assert output =~ "9 apps: 0 minimum, 9 recommended, 0 full parity"
    end
  end
end
