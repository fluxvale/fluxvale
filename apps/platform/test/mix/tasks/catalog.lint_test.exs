defmodule Mix.Tasks.Catalog.LintTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Catalog.Lint

  describe "run/1" do
    test "prints the shipped catalog's report and never fails (D1)" do
      output = capture_io(fn -> Lint.run([]) end)

      assert output =~ "forgejo: recommended"
<<<<<<< HEAD
=======
      assert output =~ "docmost: recommended"
>>>>>>> 9fb754c (test(platform): docmost joins the lint tier count (#609))
      assert output =~ "9 apps: 0 minimum, 9 recommended, 0 full parity"
    end
  end
end
