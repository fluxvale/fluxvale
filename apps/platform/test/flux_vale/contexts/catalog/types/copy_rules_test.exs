defmodule FluxVale.Catalog.Types.CopyRulesTest do
  @moduledoc false

  # The shared curated-copy guard (#611 D10) — its own arms; the three
  # list types apply it through their bounded fields.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.CopyRules

  describe "check/2" do
    test "passes plain prose" do
      assert :ok = CopyRules.check(:body, "Short plain sentences. Nothing fancy.")
    end

    test "rejects em dashes and semicolons, naming the field and the fix" do
      assert {:error, message} = CopyRules.check("alt", "A shot — the main screen")
      assert message == "alt must not contain an em dash. Use short plain sentences."

      assert {:error, message} = CopyRules.check(:answer, "Yes; it works.")
      assert message == "answer must not contain a semicolon. Use short plain sentences."
    end
  end

  describe "bounded/4" do
    test "passes in-bounds prose through unchanged, then applies the copy rules" do
      text = "A caption within bounds."

      assert {:ok, ^text} = CopyRules.bounded(:caption, text, 1, 160)

      # In bounds but breaking the copy rules: the copy error, not the
      # length error.
      semicolon = "In bounds; wrong punctuation."

      assert {:error, message} = CopyRules.bounded(:caption, semicolon, 1, 160)
      assert message =~ "must not contain a semicolon"
    end

    test "rejects out-of-bounds prose with the measured length" do
      assert {:error, message} = CopyRules.bounded(:alt, "short", 10, 140)
      assert message == "alt must be 10-140 characters, got 5"

      assert {:error, message} = CopyRules.bounded(:alt, String.duplicate("a", 141), 10, 140)
      assert message == "alt must be 10-140 characters, got 141"
    end
  end
end
