defmodule Mix.Tasks.Catalog.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Catalog.Lint

  describe "run/1" do
    test "prints the shipped catalog's report and never fails (D1)" do
      output = capture_io(fn -> Lint.run([]) end)

      assert output =~ "forgejo: recommended"
      assert output =~ "7 apps: 0 minimum, 7 recommended, 0 full parity"
    end
  end
end
