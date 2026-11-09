defmodule FluxVale.Catalog.Types.FeatureListTest do
  @moduledoc false

  # The feature card list type (#611) — casting and validation
  # semantics live here, mirroring ScreenshotListTest's shape.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.FeatureList

  @valid [
    %{
      "icon" => "hero-archive-box",
      "title" => "Repositories",
      "body" => "Host your own repositories with full control."
    },
    %{
      "icon" => "hero-bolt",
      "title" => "Actions CI",
      "body" => "Run builds and tests on every push, in your own forge."
    }
  ]

  # The shape every single-item test builds from.
  @first Enum.at(@valid, 0)

  describe "icons/0" do
    test "exposes the allowlist the renderer derives from (plan §4.3)" do
      assert "hero-archive-box" in FeatureList.icons()
      assert "hero-user-group" in FeatureList.icons()
      # The full <.icon name> form, so a card's icon renders as-is.
      assert Enum.all?(FeatureList.icons(), &String.starts_with?(&1, "hero-"))
    end

    # The icons are data-driven (the DB carries the name, no template
    # literal), so Tailwind only generates a .hero-* class when the
    # allowlist file itself is inside the @source scan. Dropping that
    # scan line fails silently — every feature tile renders blank — so
    # pin the wiring here (#611 S4, found in visual QA).
    test "the allowlist file rides Tailwind's @source scan so every icon ships CSS" do
      app_css = File.read!("assets/css/app.css")
      assert app_css =~ "lib/flux_vale/contexts/catalog/types/feature_list.ex"
    end

    # The other leg of "never a blank tile": every allowlisted name
    # must exist in the pinned heroicons dep, or the class generates
    # against nothing. A typo'd widening would pass validation and
    # render blank icons silently — the moduledoc's "every name exists
    # in the pinned dep" claim, enforced.
    test "every allowlisted name exists in the pinned heroicons dep" do
      outline_dir = "deps/heroicons/optimized/24/outline"

      for icon <- FeatureList.icons() do
        svg = String.replace_prefix(icon, "hero-", "") <> ".svg"
        path = Path.join(outline_dir, svg)
        assert File.exists?(path), "#{icon} has no SVG at #{path}"
      end
    end
  end

  describe "new/1" do
    test "casts string-keyed items (YAML/JSON/Admin form shape)" do
      assert {:ok, features} = FeatureList.new(@valid)

      assert features == [
               %{
                 icon: "hero-archive-box",
                 title: "Repositories",
                 body: "Host your own repositories with full control."
               },
               %{
                 icon: "hero-bolt",
                 title: "Actions CI",
                 body: "Run builds and tests on every push, in your own forge."
               }
             ]
    end

    test "accepts atom keys" do
      assert {:ok, [feature]} =
               FeatureList.new([
                 %{
                   icon: "hero-archive-box",
                   title: "Repositories",
                   body: "Host your own repositories with full control."
                 }
               ])

      assert feature.title == "Repositories"
    end

    test "accepts between one and four items" do
      four = @valid ++ @valid
      assert {:ok, features} = FeatureList.new(four)
      assert length(features) == 4
    end

    test "rejects five items — the 2x2 grid caps at four" do
      five = @valid ++ @valid ++ [Enum.at(@valid, 1)]

      assert {:error, message} = FeatureList.new(five)
      assert message == "expected 1-4 feature cards, got 5"
    end

    test "rejects unknown fields — a typo'd item fails loudly" do
      typo = [Map.put(@first, "titel", "Repositories")]

      assert {:error, message} = FeatureList.new(typo)

      assert message ==
               ~s|unknown field(s) ["titel"]; supported: [:body, :icon, :title]|
    end

    test "rejects icons outside the allowlist, naming the set" do
      off_list = %{@first | "icon" => "hero-star"}

      assert {:error, message} = FeatureList.new([off_list])
      assert message =~ ~s(unknown icon "hero-star")
      assert message =~ "hero-archive-box"

      # A bare name (no hero- prefix) is not the component's form.
      bare = %{@first | "icon" => "archive-box"}
      assert {:error, message} = FeatureList.new([bare])
      assert message =~ "unknown icon \"archive-box\""
    end

    test "requires icon, and rejects non-string icons" do
      assert {:error, message} = FeatureList.new([Map.delete(@first, "icon")])
      assert message == "icon is required"

      assert {:error, message} = FeatureList.new([%{@first | "icon" => 5}])
      assert message == "icon must be one of the allowlisted heroicons, got: 5"
    end

    test "bounds title to 3-60 chars and body to 20-220 chars" do
      short_title = %{@first | "title" => "ab"}
      assert {:error, message} = FeatureList.new([short_title])
      assert message == "title must be 3-60 characters, got 2"

      long_title = %{@first | "title" => String.duplicate("t", 61)}
      assert {:error, message} = FeatureList.new([long_title])
      assert message == "title must be 3-60 characters, got 61"

      assert {:error, message} = FeatureList.new([Map.delete(@first, "title")])
      assert message == "title is required"

      short_body = %{@first | "body" => "too short, no body"}
      assert {:error, message} = FeatureList.new([short_body])
      assert message == "body must be 20-220 characters, got 18"

      long_body = %{@first | "body" => String.duplicate("b", 221)}
      assert {:error, message} = FeatureList.new([long_body])
      assert message == "body must be 20-220 characters, got 221"

      assert {:error, message} = FeatureList.new([Map.delete(@first, "body")])
      assert message == "body is required"

      # Wrong types are named, not crashed on (the unquoted-YAML shape).
      assert {:error, message} = FeatureList.new([%{@first | "title" => 5}])
      assert message == "title must be a string, got: 5"

      assert {:error, message} = FeatureList.new([%{@first | "body" => []}])
      assert message == "body must be a string, got: []"
    end

    test "rejects em dashes and semicolons in the prose fields (D10)" do
      em_dash = %{@first | "title" => "Repos — your own"}
      assert {:error, message} = FeatureList.new([em_dash])
      assert message == "title must not contain an em dash. Use short plain sentences."

      semicolon = %{@first | "body" => "Your own repositories; no limits."}
      assert {:error, message} = FeatureList.new([semicolon])
      assert message == "body must not contain a semicolon. Use short plain sentences."
    end

    test "rejects non-map items and non-list input" do
      assert {:error, message} = FeatureList.new(["hero-archive-box"])
      assert message =~ "each feature card must be a map"

      assert {:error, message} = FeatureList.new(@first)
      assert message == "expected a list of feature cards"
    end

    test "rejects malformed key shapes" do
      assert {:error, message} = FeatureList.new([Map.put(@first, 1, "x")])
      assert message =~ "feature card keys must be strings or atoms"
    end
  end

  describe "cast_input/2, dump_to_native/2, and cast_stored/2" do
    test "nil is the absent state — [] in and out of storage" do
      assert {:ok, []} = FeatureList.cast_input(nil, [])
      assert {:ok, []} = FeatureList.dump_to_native(nil, [])
      assert {:ok, []} = FeatureList.cast_stored(nil, [])
    end

    test "cast_input surfaces the cast error for a malformed list" do
      assert {:error, message} = FeatureList.cast_input([%{"icon" => "hero-bolt"}], [])
      assert message =~ "title is required"

      assert {:error, message} = FeatureList.cast_input("nope", [])
      assert message == "expected a list of feature cards"
    end

    test "dumps to string-keyed maps and re-casts on read (jsonb round-trip)" do
      {:ok, features} = FeatureList.new(@valid)

      assert {:ok, dumped} = FeatureList.dump_to_native(features, [])

      assert dumped == [
               %{
                 "icon" => "hero-archive-box",
                 "title" => "Repositories",
                 "body" => "Host your own repositories with full control."
               },
               %{
                 "icon" => "hero-bolt",
                 "title" => "Actions CI",
                 "body" => "Run builds and tests on every push, in your own forge."
               }
             ]

      assert {:ok, ^features} = FeatureList.cast_stored(dumped, [])
    end

    test "the defensive dump/stored arms reject non-lists" do
      assert {:error, message} = FeatureList.dump_to_native("nope", [])
      assert message == "expected a list of feature cards"

      assert {:error, message} = FeatureList.cast_stored("nope", [])
      assert message == "expected a list of feature cards"
    end
  end
end
