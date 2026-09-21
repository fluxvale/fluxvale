defmodule FluxVale.Catalog.Types.EnvVarSpecTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.EnvVarSpec

  describe "new/1" do
    test "casts a string-keyed spec (YAML/JSON/Admin form shape)" do
      assert {:ok, spec} =
               EnvVarSpec.new(%{
                 "label" => "SMTP Host",
                 "description" => "SMTP server hostname",
                 "type" => "string",
                 "required" => false,
                 "default" => "",
                 "secret" => false
               })

      assert spec.label == "SMTP Host"
      assert spec.description == "SMTP server hostname"
      assert spec.type == :string
      assert spec.required == false
      assert spec.default == ""
      assert spec.secret == false
    end

    test "accepts atom keys and fills optional-field defaults" do
      assert {:ok, spec} = EnvVarSpec.new(%{label: "Port", type: "integer", default: 587})

      assert spec.description == nil
      assert spec.required == false
      assert spec.secret == false
      assert spec.type == :integer
    end

    test "passes valid structs through re-validation unchanged" do
      spec = %EnvVarSpec{label: "L", type: :boolean, required: false, secret: false}

      assert {:ok, ^spec} = EnvVarSpec.new(spec)
    end

    test "rejects hand-built structs with invalid field values (no bypass)" do
      bad = %EnvVarSpec{label: "L", type: :string, required: "yes"}

      assert {:error, message} = EnvVarSpec.new(bad)
      assert message =~ "required must be a boolean"
    end

    test "rejects unknown fields — a typo'd label fails loudly" do
      assert {:error, message} = EnvVarSpec.new(%{"labl" => "x", "type" => "string"})
      assert message =~ "unknown field"
      assert message =~ "labl"
    end

    test "rejects unknown types" do
      assert {:error, message} = EnvVarSpec.new(%{"label" => "x", "type" => "text"})
      assert message =~ ~s(unknown type "text")
    end

    test "requires label and type" do
      assert {:error, "label is required"} = EnvVarSpec.new(%{"type" => "string"})
      assert {:error, "type is required"} = EnvVarSpec.new(%{"label" => "x"})
    end

    test "type-checks default against type" do
      assert {:error, message} =
               EnvVarSpec.new(%{"label" => "x", "type" => "integer", "default" => "587"})

      assert message =~ "does not match type :integer"

      assert {:ok, _int} =
               EnvVarSpec.new(%{"label" => "x", "type" => "integer", "default" => 587})

      assert {:ok, _bool} =
               EnvVarSpec.new(%{"label" => "x", "type" => "boolean", "default" => true})

      assert {:ok, _str} =
               EnvVarSpec.new(%{"label" => "x", "type" => "string", "default" => "587"})
    end

    test "enforces real booleans for required and secret" do
      assert {:error, message} =
               EnvVarSpec.new(%{"label" => "x", "type" => "string", "required" => "yes"})

      assert message =~ "required must be a boolean"

      assert {:error, message} =
               EnvVarSpec.new(%{"label" => "x", "type" => "string", "secret" => 1})

      assert message =~ "secret must be a boolean"
    end

    test "rejects non-map input" do
      wrong_type = Enum.at(["not a map"], 0)

      assert {:error, message} = EnvVarSpec.new(wrong_type)
      assert message =~ "expected a map"
    end

    test "returns an error for non-string spec keys — never raises (cast path)" do
      assert {:error, message} = EnvVarSpec.new(%{1 => "x"})
      assert message =~ "spec keys must be strings or atoms"
    end
  end

  describe "dump/1" do
    test "produces the string-keyed jsonb storage shape" do
      {:ok, spec} =
        EnvVarSpec.new(%{
          "label" => "Password",
          "type" => "string",
          "default" => "",
          "secret" => true
        })

      assert EnvVarSpec.dump(spec) == %{
               "label" => "Password",
               "type" => "string",
               "default" => "",
               "required" => false,
               "secret" => true
             }
    end

    test "omits absent optionals (nil description/default)" do
      {:ok, spec} = EnvVarSpec.new(%{"label" => "x", "type" => "string"})
      dumped = EnvVarSpec.dump(spec)

      refute Map.has_key?(dumped, "description")
      refute Map.has_key?(dumped, "default")
    end
  end

  describe "valid_name?/1" do
    test "accepts POSIX-shaped names, rejects the rest" do
      assert EnvVarSpec.valid_name?("SMTP_HOST")
      assert EnvVarSpec.valid_name?("private_var_2")
      assert EnvVarSpec.valid_name?("_leading_underscore")

      refute EnvVarSpec.valid_name?("2TCP")
      refute EnvVarSpec.valid_name?("SMTP-HOST")
      refute EnvVarSpec.valid_name?("has space")
      refute EnvVarSpec.valid_name?("")
      refute EnvVarSpec.valid_name?(:atom)
      refute EnvVarSpec.valid_name?(123)
    end
  end
end
