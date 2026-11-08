defmodule FluxVale.Catalog.Types.OidcWiringTest do
  @moduledoc false

  # The OIDC wiring recipe type (#597) — casting and validation
  # semantics live here, mirroring FirstRunContractTest's shape.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.OidcWiring

  # The Vaultwarden seed's recipe, the shape every test builds from.
  @valid %{
    "kind" => "env",
    "issuer_env" => "SSO_AUTHORITY",
    "client_id_env" => "SSO_CLIENT_ID",
    "client_secret_env" => "SSO_CLIENT_SECRET",
    "enabled_env" => "SSO_ENABLED",
    "pkce" => true
  }

  describe "new/1" do
    test "casts a string-keyed recipe (YAML/JSON/Admin form shape)" do
      assert {:ok, wiring} = OidcWiring.new(@valid)

      assert wiring == %OidcWiring{
               kind: :env,
               issuer_env: "SSO_AUTHORITY",
               client_id_env: "SSO_CLIENT_ID",
               client_secret_env: "SSO_CLIENT_SECRET",
               enabled_env: "SSO_ENABLED",
               pkce: true
             }
    end

    test "accepts atom keys, and enabled_env is optional" do
      assert {:ok, wiring} =
               OidcWiring.new(%{
                 kind: :env,
                 issuer_env: "SSO_AUTHORITY",
                 client_id_env: "SSO_CLIENT_ID",
                 client_secret_env: "SSO_CLIENT_SECRET",
                 pkce: false
               })

      assert wiring.enabled_env == nil
      assert wiring.pkce == false

      # An explicit null is absence too (an admin form clears the
      # field rather than dropping the key).
      cleared = Map.put(@valid, "enabled_env", nil)
      assert {:ok, wiring} = OidcWiring.new(cleared)
      assert wiring.enabled_env == nil
    end

    test "casts the in_app kind atom — the v2 union rides the type now" do
      assert {:ok, wiring} = OidcWiring.new(%{@valid | "kind" => "in_app"})
      assert wiring.kind == :in_app

      # The atom survives the jsonb round-trip as its string form.
      dumped = OidcWiring.dump(wiring)
      assert dumped["kind"] == "in_app"
      assert {:ok, ^wiring} = OidcWiring.new(dumped)
    end

    test "known_kinds/0 lists the closed set the admin select derives from" do
      assert OidcWiring.known_kinds() == [:env, :in_app]
    end

    test "passes valid structs through re-validation unchanged" do
      {:ok, wiring} = OidcWiring.new(@valid)
      assert {:ok, ^wiring} = OidcWiring.new(wiring)
    end

    test "rejects hand-built structs with invalid field values (no bypass)" do
      {:ok, valid} = OidcWiring.new(@valid)
      bad = struct!(valid, pkce: "yes")

      assert {:error, message} = OidcWiring.new(bad)
      assert message =~ "pkce must be a boolean"
    end

    test "rejects unknown fields — a typo'd recipe fails loudly" do
      typo = Map.put(@valid, "issur_env", "SSO_AUTHORITY")

      assert {:error, message} = OidcWiring.new(typo)

      assert message ==
               ~s|unknown field(s) ["issur_env"]; supported: [:client_id_env, :client_secret_env, :enabled_env, :issuer_env, :kind, :pkce]|
    end

    test "rejects unknown kinds" do
      assert {:error, message} = OidcWiring.new(%{@valid | "kind" => "cli"})
      assert message =~ ~s(unknown kind "cli")
    end

    test "requires kind, the three env names, and pkce" do
      for missing <- ["kind", "issuer_env", "client_id_env", "client_secret_env", "pkce"] do
        without = Map.delete(@valid, missing)

        assert {:error, message} = OidcWiring.new(without)
        assert message =~ "#{missing} is required"
      end

      # enabled_env is the one optional field — absence is fine.
      no_toggle = Map.delete(@valid, "enabled_env")
      assert {:ok, _wiring} = OidcWiring.new(no_toggle)
    end

    test "rejects malformed env-var names on every env field, naming the field" do
      for field <- ["issuer_env", "client_id_env", "client_secret_env", "enabled_env"] do
        assert {:error, message} = OidcWiring.new(%{@valid | field => "SSO-AUTHORITY"})
        assert message =~ "#{field} is not a valid env-var name"
      end
    end

    test "rejects non-string env names — an unquoted YAML shape fails, not crashes" do
      assert {:error, message} = OidcWiring.new(%{@valid | "issuer_env" => 5})
      assert message =~ "issuer_env must be an env-var name string"
    end

    test "rejects non-map input" do
      assert {:error, message} = OidcWiring.new("nope")
      assert message =~ "expected a map"
    end

    test "rejects malformed shapes on the defensive cast arms" do
      bad_key = Map.put(@valid, 1, "x")
      assert {:error, message} = OidcWiring.new(bad_key)
      assert message =~ "recipe keys must be strings or atoms"

      bad_kind = %{@valid | "kind" => 5}
      assert {:error, message} = OidcWiring.new(bad_kind)
      assert message =~ "kind must be one of"

      assert {:error, message} = OidcWiring.dump_to_native("nope", [])
      assert message =~ "expected an OIDC wiring recipe"

      assert {:error, message} = OidcWiring.cast_stored("nope", [])
      assert message =~ "expected an OIDC wiring recipe"
    end
  end

  describe "dump/1 and the jsonb round-trip" do
    test "dumps to a string-keyed map and re-casts on read" do
      {:ok, wiring} = OidcWiring.new(@valid)

      dumped = OidcWiring.dump(wiring)

      assert dumped == %{
               "kind" => "env",
               "issuer_env" => "SSO_AUTHORITY",
               "client_id_env" => "SSO_CLIENT_ID",
               "client_secret_env" => "SSO_CLIENT_SECRET",
               "enabled_env" => "SSO_ENABLED",
               "pkce" => true
             }

      assert {:ok, ^wiring} = OidcWiring.new(dumped)
    end

    test "omits a nil enabled_env from the dump" do
      no_toggle = Map.delete(@valid, "enabled_env")
      {:ok, wiring} = OidcWiring.new(no_toggle)

      dumped = OidcWiring.dump(wiring)
      refute Map.has_key?(dumped, "enabled_env")
    end

    test "the nullable attribute's nil arms — cast, dump, and stored read" do
      assert {:ok, nil} = OidcWiring.cast_input(nil, [])
      assert {:ok, nil} = OidcWiring.dump_to_native(nil, [])
      assert {:ok, nil} = OidcWiring.cast_stored(nil, [])
    end

    test "cast_input surfaces the cast error for a malformed map" do
      assert {:error, message} = OidcWiring.cast_input(%{@valid | "kind" => "nope"}, [])
      assert message =~ ~s(unknown kind "nope")
    end
  end

  # `oidc_wiring` is a public attribute on the app-version routes,
  # rendered with Jason (#362's FirstRunContract lesson).
  describe "Jason encoding" do
    test "round-trips the storage shape: kind as a string, enabled_env omitted when nil" do
      no_toggle = Map.delete(@valid, "enabled_env")
      {:ok, wiring} = OidcWiring.new(no_toggle)

      encoded =
        wiring
        |> Jason.encode!()
        |> Jason.decode!()

      assert encoded == %{
               "kind" => "env",
               "issuer_env" => "SSO_AUTHORITY",
               "client_id_env" => "SSO_CLIENT_ID",
               "client_secret_env" => "SSO_CLIENT_SECRET",
               "pkce" => true
             }
    end
  end
end
