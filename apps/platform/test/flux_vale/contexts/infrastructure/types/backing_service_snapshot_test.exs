defmodule FluxVale.Infrastructure.Types.BackingServiceSnapshotTest do
  @moduledoc false

  # The instance-side backing-service snapshot type (#612, ADR-0045) —
  # casting and round-trip semantics, mirroring the catalog
  # BackingServiceTest's shape.

  use ExUnit.Case, async: true

  alias FluxVale.Infrastructure.Types.BackingServiceSnapshot

  # The Docmost-class snapshot: the registry row resolved at create.
  @valid %{
    "kind" => "postgres",
    "version" => "18",
    "image" => "postgres:18.6-alpine3.24",
    "port" => 5432,
    "url_env" => "DATABASE_URL",
    "cpu" => "0.10",
    "memory_mb" => 256
  }

  describe "new/1" do
    test "casts a string-keyed snapshot (the jsonb round-trip shape)" do
      assert {:ok, snapshot} = BackingServiceSnapshot.new(@valid)

      assert snapshot == %BackingServiceSnapshot{
               kind: :postgres,
               version: "18",
               image: "postgres:18.6-alpine3.24",
               port: 5432,
               url_env: "DATABASE_URL",
               cpu: "0.10",
               memory_mb: 256
             }
    end

    test "accepts atom keys" do
      assert {:ok, snapshot} =
               BackingServiceSnapshot.new(%{
                 kind: "redis",
                 version: "8",
                 image: "redis:8.10.3-alpine3.23",
                 port: 6379,
                 url_env: "REDIS_URL",
                 cpu: "0.05",
                 memory_mb: 64
               })

      assert snapshot.kind == :redis
      assert snapshot.port == 6379
    end

    test "dump/cast_stored round-trips through the string-keyed map" do
      {:ok, snapshot} = BackingServiceSnapshot.new(@valid)
      dumped = BackingServiceSnapshot.dump(snapshot)

      assert dumped == %{
               "kind" => "postgres",
               "version" => "18",
               "image" => "postgres:18.6-alpine3.24",
               "port" => 5432,
               "url_env" => "DATABASE_URL",
               "cpu" => "0.10",
               "memory_mb" => 256
             }

      assert {:ok, ^snapshot} = BackingServiceSnapshot.cast_stored(dumped, [])
    end

    test "passes valid structs through re-validation unchanged" do
      {:ok, snapshot} = BackingServiceSnapshot.new(@valid)
      assert {:ok, ^snapshot} = BackingServiceSnapshot.new(snapshot)
    end

    test "rejects hand-built structs with invalid field values (no bypass)" do
      {:ok, valid} = BackingServiceSnapshot.new(@valid)
      bad = struct!(valid, kind: :mariadb)

      assert {:error, message} = BackingServiceSnapshot.new(bad)
      assert message =~ "unknown kind :mariadb"
    end

    test "rejects unknown fields — a typo'd snapshot fails loudly" do
      typo = Map.put(@valid, "image_ref", "postgres:18")

      assert {:error, message} = BackingServiceSnapshot.new(typo)

      assert message ==
               ~s|unknown field(s) ["image_ref"]; supported: [:cpu, :image, :kind, :memory_mb, :port, :url_env, :version]|
    end

    test "requires every field" do
      for missing <- Map.keys(@valid) do
        without = Map.delete(@valid, missing)

        assert {:error, message} = BackingServiceSnapshot.new(without)
        assert message =~ "#{missing} is required"
      end
    end

    test "kind stays the closed set" do
      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "kind" => "valkey"})
      assert message =~ ~s(unknown kind "valkey")
    end

    test "version is the major digit string (the declaration's shape)" do
      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "version" => "18.6"})
      assert message =~ "version must be a major-version digit string"
    end

    test "image must be a non-empty string" do
      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "image" => ""})
      assert message =~ "image must be a non-empty image-ref string"

      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "image" => :not_a_ref})
      assert message =~ "image must be a non-empty image-ref string"
    end

    test "port and memory_mb must be positive integers" do
      for bad_port <- [0, -1, "5432", 5432.0] do
        assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "port" => bad_port})
        assert message =~ "port must be a positive integer"
      end

      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "memory_mb" => 0})
      assert message =~ "memory_mb must be a positive integer"
    end

    test "cpu must be a positive decimal-parseable string — the carve's input" do
      for bad <- ["abc", "0.10x", "0", "-0.10", 0.10, :small] do
        assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "cpu" => bad})
        assert message =~ "cpu must be a positive decimal string"
      end
    end

    test "url_env stays POSIX-shaped" do
      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "url_env" => "DB-URL"})
      assert message =~ "url_env is not a valid env-var name"
    end

    test "rejects non-map input" do
      assert {:error, message} = BackingServiceSnapshot.new("nope")
      assert message =~ "expected a map"
    end

    test "cast_input threads new/1's verdict (the Ash cast path)" do
      assert {:ok, snapshot} = BackingServiceSnapshot.cast_input(@valid, [])
      assert snapshot.url_env == "DATABASE_URL"

      kindless = Map.delete(@valid, "kind")

      assert {:error, message} = BackingServiceSnapshot.cast_input(kindless, [])
      assert message =~ "kind is required"
    end

    test "rejects non-string/atom keys" do
      assert {:error, message} = BackingServiceSnapshot.new(%{123 => "x"})
      assert message =~ "snapshot keys must be strings or atoms"
    end

    test "rejects non-string kind/version/url_env values" do
      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "kind" => 5})
      assert message =~ "kind must be one of"

      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "version" => 18})
      assert message =~ "version must be a major-version digit string"

      assert {:error, message} = BackingServiceSnapshot.new(%{@valid | "url_env" => 5})
      assert message =~ "url_env must be an env-var name string"
    end
  end

  describe "cast_stored/2" do
    test "rejects non-map storage" do
      assert {:error, message} = BackingServiceSnapshot.cast_stored("nope", [])
      assert message =~ "expected a backing-service snapshot"
    end
  end

  describe "dump_to_native/2" do
    test "rejects non-struct input" do
      assert {:error, message} = BackingServiceSnapshot.dump_to_native(@valid, [])
      assert message =~ "expected a backing-service snapshot"
    end
  end
end
