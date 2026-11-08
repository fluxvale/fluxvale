defmodule FluxVale.Catalog.Types.BackingServiceTest do
  @moduledoc false

  # The bundled backing-service declaration type (#612, ADR-0045) —
  # casting and validation semantics, mirroring OidcWiringTest's shape.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.BackingService

  # The Docmost-class declaration, the shape every test builds from.
  @valid %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"}

  describe "new/1" do
    test "casts a string-keyed declaration (YAML/JSON/Admin form shape)" do
      assert {:ok, service} = BackingService.new(@valid)

      assert service == %BackingService{
               kind: :postgres,
               version: "18",
               url_env: "DATABASE_URL"
             }
    end

    test "accepts atom keys" do
      assert {:ok, service} =
               BackingService.new(%{kind: :redis, version: "8", url_env: "REDIS_URL"})

      assert service.kind == :redis
      assert service.version == "8"
      assert service.url_env == "REDIS_URL"
    end

    test "known_kinds/0 lists the closed set the admin select derives from" do
      assert BackingService.known_kinds() == [:postgres, :redis]
    end

    test "passes valid structs through re-validation unchanged" do
      {:ok, service} = BackingService.new(@valid)
      assert {:ok, ^service} = BackingService.new(service)
    end

    test "rejects hand-built structs with invalid field values (no bypass)" do
      {:ok, valid} = BackingService.new(@valid)
      bad = struct!(valid, kind: :mariadb)

      assert {:error, message} = BackingService.new(bad)
      assert message =~ "unknown kind :mariadb"
    end

    test "rejects unknown fields — a typo'd declaration fails loudly" do
      typo = Map.put(@valid, "urlenv", "DATABASE_URL")

      assert {:error, message} = BackingService.new(typo)

      assert message ==
               ~s|unknown field(s) ["urlenv"]; supported: [:kind, :url_env, :version]|
    end

    test "rejects unknown kinds" do
      assert {:error, message} = BackingService.new(%{@valid | "kind" => "valkey"})
      assert message =~ ~s(unknown kind "valkey")
    end

    test "requires kind, version, and url_env" do
      for missing <- ["kind", "version", "url_env"] do
        without = Map.delete(@valid, missing)

        assert {:error, message} = BackingService.new(without)
        assert message =~ "#{missing} is required"
      end
    end

    test "version is the MAJOR only — minor pins and decorated strings are shape errors" do
      for bad <- ["16.4", "v16", "18-alpine", "latest"] do
        assert {:error, message} = BackingService.new(%{@valid | "version" => bad})

        assert message =~
                 "version must be a major-version digit string, got: #{inspect(bad)}"
      end
    end

    test "rejects a non-string version — an unquoted YAML integer fails, not crashes" do
      assert {:error, message} = BackingService.new(%{@valid | "version" => 18})
      assert message =~ "version must be a major-version digit string, got: 18"
    end

    test "rejects malformed env-var names on url_env" do
      assert {:error, message} = BackingService.new(%{@valid | "url_env" => "DATABASE-URL"})
      assert message =~ "url_env is not a valid env-var name"
    end

    test "rejects non-string env names" do
      assert {:error, message} = BackingService.new(%{@valid | "url_env" => 5})
      assert message =~ "url_env must be an env-var name string"
    end

    test "rejects non-map input" do
      assert {:error, message} = BackingService.new("nope")
      assert message =~ "expected a map"
    end

    test "rejects malformed shapes on the defensive cast arms" do
      bad_key = Map.put(@valid, 1, "x")
      assert {:error, message} = BackingService.new(bad_key)
      assert message =~ "declaration keys must be strings or atoms"

      bad_kind = %{@valid | "kind" => 5}
      assert {:error, message} = BackingService.new(bad_kind)
      assert message =~ "kind must be one of"

      assert {:error, message} = BackingService.dump_to_native("nope", [])
      assert message =~ "expected a backing-service declaration"

      assert {:error, message} = BackingService.cast_stored("nope", [])
      assert message =~ "expected a backing-service declaration"
    end
  end

  describe "dump/1 and the jsonb round-trip" do
    test "dumps to a string-keyed map and re-casts on read" do
      {:ok, service} = BackingService.new(@valid)

      dumped = BackingService.dump(service)

      assert dumped == %{
               "kind" => "postgres",
               "version" => "18",
               "url_env" => "DATABASE_URL"
             }

      assert {:ok, ^service} = BackingService.new(dumped)
    end

    test "cast_input surfaces the cast error for a malformed map" do
      assert {:error, message} = BackingService.cast_input(%{@valid | "kind" => "nope"}, [])
      assert message =~ ~s(unknown kind "nope")
    end

    test "an array of declarations casts, dumps, and re-reads element-wise" do
      pair = [
        @valid,
        %{"kind" => "redis", "version" => "8", "url_env" => "REDIS_URL"}
      ]

      array = {:array, BackingService}

      assert {:ok, [postgres, redis]} = Ash.Type.cast_input(array, pair, [])
      assert postgres.kind == :postgres
      assert redis.kind == :redis

      assert {:ok, dumped} = Ash.Type.dump_to_native(array, [postgres, redis], [])

      assert dumped == [
               %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"},
               %{"kind" => "redis", "version" => "8", "url_env" => "REDIS_URL"}
             ]

      assert {:ok, [^postgres, ^redis]} = Ash.Type.cast_stored(array, dumped, [])
    end

    test "a nil element fails the array cast — the declaration is never absent per service" do
      array = {:array, BackingService}

      assert {:error, _errors} = Ash.Type.cast_input(array, [nil], [])
    end
  end

  # `backing_services` is a public attribute on the app-version routes,
  # rendered with Jason (#362's FirstRunContract lesson).
  describe "Jason encoding" do
    test "round-trips the storage shape: kind as a string" do
      {:ok, service} = BackingService.new(@valid)

      encoded =
        service
        |> Jason.encode!()
        |> Jason.decode!()

      assert encoded == %{
               "kind" => "postgres",
               "version" => "18",
               "url_env" => "DATABASE_URL"
             }
    end
  end

  # The OpenAPI artifact's item schema (#616 review): the rendered
  # `items` entry for the array attribute, pinned here so the artifact
  # describes kind/version/url_env instead of accepting any JSON.
  describe "json_schema/1" do
    test "describes the wire shape: closed kind, digit major, url_env" do
      assert BackingService.json_schema([]) == %{
               "type" => "object",
               "properties" => %{
                 "kind" => %{"type" => "string", "enum" => ["postgres", "redis"]},
                 "version" => %{"type" => "string"},
                 "url_env" => %{"type" => "string"}
               },
               "required" => ["kind", "version", "url_env"],
               "additionalProperties" => false
             }
    end
  end
end
