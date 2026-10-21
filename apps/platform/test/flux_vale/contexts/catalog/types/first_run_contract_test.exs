defmodule FluxVale.Catalog.Types.FirstRunContractTest do
  @moduledoc false

  # The first-run contract type (#181, ADR-0034) — casting and
  # validation semantics live here, mirroring EnvVarSpecTest's shape.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.FirstRunContract

  describe "new/1" do
    test "casts a string-keyed contract (YAML/JSON/Admin form shape)" do
      assert {:ok, contract} =
               FirstRunContract.new(%{
                 "pattern" => "first_registered_user_admin",
                 "env" => %{"APP__security__INSTALL_LOCK" => "true"},
                 "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
                 "guidance" => "Register first; you become admin."
               })

      assert contract.pattern == :first_registered_user_admin
      assert contract.env == %{"APP__security__INSTALL_LOCK" => "true"}
      assert contract.forbidden_env == ["APP__service__DISABLE_REGISTRATION"]
      assert contract.guidance == "Register first; you become admin."
    end

    test "accepts atom keys and fills optional-field defaults (empty env, nothing forbidden)" do
      assert {:ok, contract} =
               FirstRunContract.new(%{
                 pattern: :first_registered_user_admin,
                 guidance: "Just open it."
               })

      assert contract.env == %{}
      assert contract.forbidden_env == []
    end

    test "passes valid structs through re-validation unchanged" do
      contract = %FirstRunContract{
        pattern: :first_registered_user_admin,
        env: %{},
        forbidden_env: [],
        guidance: "g"
      }

      assert {:ok, ^contract} = FirstRunContract.new(contract)
    end

    test "rejects hand-built structs with invalid field values (no bypass)" do
      bad = %FirstRunContract{
        pattern: :first_registered_user_admin,
        env: %{"APP__x" => false},
        forbidden_env: [],
        guidance: "g"
      }

      assert {:error, message} = FirstRunContract.new(bad)
      assert message =~ "env APP__x must be a quoted string"
    end

    test "rejects unknown fields — a typo'd guidance fails loudly" do
      assert {:error, message} =
               FirstRunContract.new(%{
                 "pattern" => "first_registered_user_admin",
                 "guideance" => "x"
               })

      assert message =~ "unknown field"
      assert message =~ "guideance"
    end

    test "rejects unknown patterns" do
      assert {:error, message} =
               FirstRunContract.new(%{
                 "pattern" => "install_wizard",
                 "guidance" => "g"
               })

      assert message =~ ~s(unknown pattern "install_wizard")
    end

    test "requires pattern and guidance" do
      assert {:error, "pattern is required"} = FirstRunContract.new(%{"guidance" => "g"})

      assert {:error, "guidance is required"} =
               FirstRunContract.new(%{"pattern" => "first_registered_user_admin"})
    end

    test "rejects non-string env values — an unquoted YAML boolean names its key" do
      assert {:error, message} =
               FirstRunContract.new(%{
                 "pattern" => "first_registered_user_admin",
                 "guidance" => "g",
                 "env" => %{"APP__service__OPEN" => false}
               })

      assert message =~ "env APP__service__OPEN must be a quoted string"
    end

    test "rejects malformed env-var names in env and forbidden_env" do
      assert {:error, message} =
               FirstRunContract.new(%{
                 "pattern" => "first_registered_user_admin",
                 "guidance" => "g",
                 "env" => %{"not an env name" => "true"}
               })

      assert message =~ "is not a valid env-var name"

      assert {:error, message} =
               FirstRunContract.new(%{
                 "pattern" => "first_registered_user_admin",
                 "guidance" => "g",
                 "forbidden_env" => ["also not a name"]
               })

      assert message =~ "forbidden_env entries must be valid env-var names"
    end

    test "rejects a key pinned in env and locked in forbidden_env at once" do
      assert {:error, message} =
               FirstRunContract.new(%{
                 "pattern" => "first_registered_user_admin",
                 "guidance" => "g",
                 "env" => %{"APP__x" => "true"},
                 "forbidden_env" => ["APP__x"]
               })

      assert message =~ "env and forbidden_env must not overlap"
      assert message =~ "app__x"
    end

    test "rejects a case-variant pin/forbid overlap — consumers fold name case" do
      assert {:error, message} =
               FirstRunContract.new(%{
                 "pattern" => "first_registered_user_admin",
                 "guidance" => "g",
                 "env" => %{"APP__Service__X" => "true"},
                 "forbidden_env" => ["APP__service__x"]
               })

      assert message =~ "env and forbidden_env must not overlap"
      assert message =~ "app__service__x"
    end

    test "rejects non-map input" do
      assert {:error, message} = FirstRunContract.new("nope")
      assert message =~ "expected a map"
    end

    test "rejects malformed shapes on every field — the defensive cast arms" do
      base = %{"pattern" => "first_registered_user_admin", "guidance" => "g"}

      bad_key = Map.put(base, 1, "x")
      assert {:error, message} = FirstRunContract.new(bad_key)
      assert message =~ "contract keys must be strings or atoms"

      bad_pattern = %{base | "pattern" => 5}
      assert {:error, message} = FirstRunContract.new(bad_pattern)
      assert message =~ "pattern must be one of"

      bad_env = Map.put(base, "env", "nope")
      assert {:error, message} = FirstRunContract.new(bad_env)
      assert message =~ "env must be a map"

      bad_forbidden = Map.put(base, "forbidden_env", "nope")
      assert {:error, message} = FirstRunContract.new(bad_forbidden)
      assert message =~ "forbidden_env must be a list"

      bad_guidance = %{base | "guidance" => 5}
      assert {:error, message} = FirstRunContract.new(bad_guidance)
      assert message =~ "guidance must be a non-empty string"

      assert {:error, message} = FirstRunContract.dump_to_native("nope", [])
      assert message =~ "expected a first-run contract"

      assert {:error, message} = FirstRunContract.cast_stored("nope", [])
      assert message =~ "expected a first-run contract"
    end
  end

  describe "dump/1 and the jsonb round-trip" do
    test "dumps to a string-keyed map and re-casts on read" do
      {:ok, contract} =
        FirstRunContract.new(%{
          "pattern" => "first_registered_user_admin",
          "env" => %{"APP__security__INSTALL_LOCK" => "true"},
          "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
          "guidance" => "g"
        })

      dumped = FirstRunContract.dump(contract)

      assert dumped == %{
               "pattern" => "first_registered_user_admin",
               "env" => %{"APP__security__INSTALL_LOCK" => "true"},
               "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
               "guidance" => "g"
             }

      assert {:ok, ^contract} = FirstRunContract.new(dumped)
    end

    test "the nullable attribute's nil arms — cast, dump, and stored read" do
      assert {:ok, nil} = FirstRunContract.cast_input(nil, [])
      assert {:ok, nil} = FirstRunContract.dump_to_native(nil, [])
      assert {:ok, nil} = FirstRunContract.cast_stored(nil, [])
    end

    test "cast_input surfaces the cast error for a malformed map" do
      assert {:error, message} =
               FirstRunContract.cast_input(%{"pattern" => "nope", "guidance" => "g"}, [])

      assert message =~ ~s(unknown pattern "nope")
    end
  end
end
