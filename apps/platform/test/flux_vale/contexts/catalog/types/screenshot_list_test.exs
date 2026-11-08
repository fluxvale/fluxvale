defmodule FluxVale.Catalog.Types.ScreenshotListTest do
  @moduledoc false

  # The screenshot list type (#611) — casting and validation semantics
  # live here, mirroring OidcWiringTest's shape.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.ScreenshotList

  @valid [
    %{
      "src" => "/images/catalog/forgejo/repositories.webp",
      "alt" => "The repositories list in Forgejo",
      "caption" => "Repository list on first open"
    },
    %{"src" => "/images/catalog/forgejo/issues.png", "alt" => "The issue tracker board"}
  ]

  # The shape every single-item test builds from.
  @first Enum.at(@valid, 0)

  describe "new/1" do
    test "casts string-keyed items (YAML/JSON/Admin form shape)" do
      assert {:ok, screenshots} = ScreenshotList.new(@valid)

      assert screenshots == [
               %{
                 src: "/images/catalog/forgejo/repositories.webp",
                 alt: "The repositories list in Forgejo",
                 caption: "Repository list on first open"
               },
               %{
                 src: "/images/catalog/forgejo/issues.png",
                 alt: "The issue tracker board",
                 caption: nil
               }
             ]
    end

    test "accepts atom keys, and caption is optional" do
      assert {:ok, [screenshot]} =
               ScreenshotList.new([
                 %{src: "/images/catalog/app/one.png", alt: "An atom keyed shot", caption: nil}
               ])

      assert screenshot.caption == nil

      # A missing caption key is absence too (the admin-form-clears
      # stance of OidcWiring's enabled_env).
      assert {:ok, [no_caption]} =
               ScreenshotList.new([
                 %{src: "/images/catalog/app/one.png", alt: "An atom keyed shot"}
               ])

      assert no_caption.caption == nil
    end

    test "accepts between one and four items" do
      one = [Enum.at(@valid, 1)]
      assert {:ok, [_shot]} = ScreenshotList.new(one)

      four = @valid ++ @valid
      assert {:ok, shots} = ScreenshotList.new(four)
      assert length(shots) == 4
    end

    test "rejects five items — the grid caps at four" do
      five = @valid ++ @valid ++ [Enum.at(@valid, 1)]

      assert {:error, message} = ScreenshotList.new(five)
      assert message == "expected 1-4 screenshots, got 5"
    end

    test "rejects unknown fields — a typo'd item fails loudly" do
      typo = [Map.put(@first, "sorc", "/images/catalog/x/y.png")]

      assert {:error, message} = ScreenshotList.new(typo)

      assert message ==
               ~s|unknown field(s) ["sorc"]; supported: [:alt, :caption, :src]|
    end

    test "rejects src outside /images/catalog with a wrong extension" do
      for bad <- [
            "images/catalog/app/one.png",
            "/images/other/app/one.png",
            "/images/catalog/app/one.jpg",
            "/images/catalog/app/one.webp.bak",
            "/images/catalog/.png"
          ] do
        assert {:error, message} = ScreenshotList.new([%{@first | "src" => bad}])
        assert message =~ "src must be an app-absolute path"
        assert message =~ inspect(bad)
      end
    end

    test "requires src, and rejects non-string src" do
      assert {:error, message} = ScreenshotList.new([Map.delete(@first, "src")])
      assert message == "src is required"

      assert {:error, message} =
               ScreenshotList.new([%{@first | "src" => 5}])

      assert message == "src must be a path string, got: 5"
    end

    test "requires alt within 10-140 chars" do
      assert {:error, message} = ScreenshotList.new([Map.delete(@first, "alt")])
      assert message == "alt is required"

      assert {:error, message} = ScreenshotList.new([%{@first | "alt" => 5}])
      assert message == "alt must be a string, got: 5"

      too_short = %{@first | "alt" => "too short"}
      assert {:error, message} = ScreenshotList.new([too_short])
      assert message == "alt must be 10-140 characters, got 9"

      too_long = %{@first | "alt" => String.duplicate("a", 141)}
      assert {:error, message} = ScreenshotList.new([too_long])
      assert message == "alt must be 10-140 characters, got 141"
    end

    test "bounds caption to 1-160 chars and rejects non-strings" do
      empty = %{@first | "caption" => ""}
      assert {:error, message} = ScreenshotList.new([empty])
      assert message == "caption must be 1-160 characters, got 0"

      too_long = %{@first | "caption" => String.duplicate("c", 161)}
      assert {:error, message} = ScreenshotList.new([too_long])
      assert message == "caption must be 1-160 characters, got 161"

      assert {:error, message} = ScreenshotList.new([%{@first | "caption" => 5}])
      assert message == "caption must be a string or null, got: 5"
    end

    test "rejects em dashes and semicolons in the prose fields (D10)" do
      em_dash = %{@first | "alt" => "The repo list — first open"}
      assert {:error, message} = ScreenshotList.new([em_dash])
      assert message == "alt must not contain an em dash. Use short plain sentences."

      semicolon = %{@first | "caption" => "First open; ready to use"}
      assert {:error, message} = ScreenshotList.new([semicolon])
      assert message == "caption must not contain a semicolon. Use short plain sentences."
    end

    test "rejects non-map items and non-list input" do
      assert {:error, message} = ScreenshotList.new(["/images/catalog/app/one.png"])
      assert message =~ "each screenshot must be a map"

      assert {:error, message} = ScreenshotList.new(@valid ++ ["nope"])
      assert message =~ "each screenshot must be a map"

      assert {:error, message} = ScreenshotList.new(@first)
      assert message == "expected a list of screenshots"
    end

    test "rejects malformed key shapes" do
      assert {:error, message} = ScreenshotList.new([Map.put(@first, 1, "x")])
      assert message =~ "screenshot keys must be strings or atoms"
    end
  end

  describe "cast_input/2, dump_to_native/2, and cast_stored/2" do
    test "nil is the absent state — [] in and out of storage" do
      assert {:ok, []} = ScreenshotList.cast_input(nil, [])
      assert {:ok, []} = ScreenshotList.dump_to_native(nil, [])
      assert {:ok, []} = ScreenshotList.cast_stored(nil, [])
    end

    test "cast_input surfaces the cast error for a malformed list" do
      assert {:error, message} =
               ScreenshotList.cast_input([%{"src" => "/images/catalog/app/one.png"}], [])

      assert message =~ "alt is required"

      assert {:error, message} = ScreenshotList.cast_input("nope", [])
      assert message == "expected a list of screenshots"
    end

    test "dumps to string-keyed maps and re-casts on read (jsonb round-trip)" do
      {:ok, screenshots} = ScreenshotList.new(@valid)

      assert {:ok, dumped} = ScreenshotList.dump_to_native(screenshots, [])

      assert dumped == [
               %{
                 "src" => "/images/catalog/forgejo/repositories.webp",
                 "alt" => "The repositories list in Forgejo",
                 "caption" => "Repository list on first open"
               },
               %{
                 "src" => "/images/catalog/forgejo/issues.png",
                 "alt" => "The issue tracker board"
               }
             ]

      # caption omits when nil (the put_if_present stance).
      without_caption = Enum.at(dumped, 1)
      refute Map.has_key?(without_caption, "caption")

      assert {:ok, ^screenshots} = ScreenshotList.cast_stored(dumped, [])
    end

    test "the defensive dump/stored arms reject non-lists" do
      assert {:error, message} = ScreenshotList.dump_to_native("nope", [])
      assert message == "expected a list of screenshots"

      assert {:error, message} = ScreenshotList.cast_stored("nope", [])
      assert message == "expected a list of screenshots"
    end
  end
end
