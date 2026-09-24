defmodule FluxVale.Catalog.Types.EnvVarSchemaTest do
  @moduledoc """
  Type-level tests for the whole-map Ash type — no database. The
  write-path behavior (Ash changeset rejection) lives in the AppVersion
  resource tests; this file pins cast/dump/round-trip semantics.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.EnvVarSchema
  alias FluxVale.Catalog.Types.EnvVarSpec

  @valid_schema %{
    "SMTP_HOST" => %{
      "label" => "SMTP Host",
      "description" => "SMTP server hostname",
      "type" => "string",
      "required" => false,
      "default" => "",
      "secret" => false
    },
    "SMTP_PORT" => %{"label" => "SMTP Port", "type" => "integer", "default" => 587},
    "ENABLE_TLS" => %{"label" => "Enable TLS", "type" => "boolean", "default" => true}
  }

  describe "cast_input/2" do
    test "casts each value to an EnvVarSpec struct, keys untouched" do
      assert {:ok, cast} = EnvVarSchema.cast_input(@valid_schema, [])

      assert Map.keys(cast) == ["ENABLE_TLS", "SMTP_HOST", "SMTP_PORT"]

      assert %EnvVarSpec{} = cast["SMTP_HOST"]
      assert cast["SMTP_HOST"].type == :string
      assert cast["SMTP_PORT"].type == :integer
      assert cast["SMTP_PORT"].default == 587
      assert cast["ENABLE_TLS"].type == :boolean
    end

    test "nil casts to the empty map (attribute default)" do
      assert {:ok, %{}} = EnvVarSchema.cast_input(nil, [])
    end

    test "rejects malformed env-var names" do
      assert {:error, message} =
               EnvVarSchema.cast_input(
                 %{"SMTP-HOST" => %{"label" => "x", "type" => "string"}},
                 []
               )

      assert message =~ "not a valid env-var name"
    end

    test "errors carry the offending env-var name" do
      assert {:error, message} =
               EnvVarSchema.cast_input(
                 %{"SMTP_HOST" => %{"labl" => "x", "type" => "string"}},
                 []
               )

      assert message =~ "SMTP_HOST"
      assert message =~ "unknown field"
    end

    test "rejects non-map input" do
      assert :error = EnvVarSchema.cast_input("nope", [])
    end
  end

  describe "dump_to_native/2 + cast_stored/2 (jsonb round-trip)" do
    test "structs dump to string-keyed maps and re-cast on read" do
      {:ok, cast} = EnvVarSchema.cast_input(@valid_schema, [])
      {:ok, native} = EnvVarSchema.dump_to_native(cast, [])

      assert %{} = native
      assert native["SMTP_HOST"]["type"] == "string"
      assert is_map(native["SMTP_HOST"])
      assert not is_struct(native["SMTP_HOST"], EnvVarSpec)

      # Read path: stored string-keyed maps re-validate into structs.
      assert {:ok, restored} = EnvVarSchema.cast_stored(native, [])
      assert %EnvVarSpec{} = restored["SMTP_HOST"]
      assert restored["SMTP_PORT"].default == 587
    end

    test "cast_stored rejects non-map storage" do
      assert :error = EnvVarSchema.cast_stored("nope", [])
    end
  end

  describe "nil and non-map inputs" do
    test "dump_to_native of nil is an empty map (jsonb column nullable-free)" do
      assert {:ok, %{}} = EnvVarSchema.dump_to_native(nil, [])
    end

    test "dump_to_native of a non-map is :error" do
      non_map = Enum.at(["nope"], 0)
      assert :error = EnvVarSchema.dump_to_native(non_map, [])
    end

    test "cast_stored of nil is an empty map" do
      assert {:ok, %{}} = EnvVarSchema.cast_stored(nil, [])
    end
  end
end
