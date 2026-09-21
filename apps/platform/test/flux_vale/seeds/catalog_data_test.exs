defmodule FluxVale.Seeds.CatalogDataTest do
  @moduledoc """
  Unit tests for YAML normalization — no database. Env-var spec validation
  itself moved to the `EnvVarSchema` type (v1 validated here); these tests
  pin only what the loader owns: Decimal/DateTime conversion, map defaults,
  and pass-through of the raw schema.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Seeds.CatalogData

  @fixture Path.join([__DIR__, "../../support/fixtures/catalog_data_with_env_vars.yaml"])

  describe "entries/1" do
    test "normalizes the shipped catalog_data.yaml" do
      [entry] = CatalogData.entries(default_catalog_path())

      assert entry.category == %{
               name: "Media & Entertainment",
               slug: "media",
               description:
                 "Self-hosted media servers for streaming, reading, and browsing your library."
             }

      assert [%{slug: "kavita"} = app] = entry.apps
      assert hd(app.versions).image == "jvmilazz0/kavita:0.9.0.2"
    end

    test "converts quoted-string cpu cores to Decimal and ISO 8601 to DateTime" do
      version = first_version(CatalogData.entries(default_catalog_path()))

      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.published_at == ~U[2026-05-14 14:04:05Z]
    end

    test "defaults omitted env maps to %{}" do
      version = first_version(CatalogData.entries(default_catalog_path()))

      assert version.default_env_vars == %{}
      assert version.configurable_env_vars == %{}
    end

    test "passes configurable_env_vars through raw (validation is the type's job)" do
      version = first_version(CatalogData.entries(@fixture))

      assert Map.keys(version.configurable_env_vars) == [
               "ENABLE_TLS",
               "SMTP_HOST",
               "SMTP_PASSWORD",
               "SMTP_PORT"
             ]

      assert version.configurable_env_vars["SMTP_PORT"]["type"] == "integer"
    end

    test "fills loader defaults when the YAML omits optional fields" do
      minimal_yaml = """
      - category:
          name: T
          slug: t
          description: d
        apps:
          - name: A
            slug: a
            tagline: t
            description: d
            icon_url: https://example.com/i.svg
            source_url: https://example.com
            docs_url: https://example.com
            versions:
              - version: "1.0.0"
                image: test/image:1.0
                port: 8080
      """

      path = tmp_path(minimal_yaml)
      version = first_version(CatalogData.entries(path))

      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 256
      assert version.default_storage_gb == 0
      assert version.published_at == nil
    end

    test "raises naming the app when versions is missing or empty" do
      no_versions_yaml = """
      - category:
          name: T
          slug: t
          description: d
        apps:
          - name: A
            slug: a
            versions: []
      """

      assert_raise RuntimeError, ~r/app "a" must have a non-empty versions list/, fn ->
        path = tmp_path(no_versions_yaml)
        CatalogData.entries(path)
      end
    end

    test "raises on malformed published_at" do
      assert_raise MatchError, fn ->
        bad_yaml = """
        - category:
            name: T
            slug: t
            description: d
          apps:
            - name: A
              slug: a
              tagline: t
              description: d
              icon_url: https://example.com/i.svg
              source_url: https://example.com
              docs_url: https://example.com
              versions:
                - version: "1.0.0"
                  image: test/image:1.0
                  port: 8080
                  default_cpu_cores: "0.5"
                  default_memory_mb: 256
                  default_storage_gb: 1
                  release_notes: r
                  published_at: "not-a-date"
        """

        path = tmp_path(bad_yaml)
        CatalogData.entries(path)
      end
    end
  end

  defp default_catalog_path do
    :flux_vale
    |> :code.priv_dir()
    |> Path.join("repo/seeds/catalog_data.yaml")
  end

  defp first_version([entry | _rest]) do
    entry
    |> Map.fetch!(:apps)
    |> hd()
    |> Map.fetch!(:versions)
    |> hd()
  end

  defp tmp_path(contents) do
    path = Path.join(System.tmp_dir!(), "catalog_data_#{System.unique_integer()}.yaml")
    File.write!(path, contents)
    path
  end
end
