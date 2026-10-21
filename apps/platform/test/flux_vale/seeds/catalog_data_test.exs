defmodule FluxVale.Seeds.CatalogDataTest do
  @moduledoc """
  Unit tests for YAML normalization — no database. Env-var spec validation
  itself moved to the `EnvVarSchema` type (v1 validated here); these tests
  pin only what the loader owns: empty-file handling, Decimal/DateTime
  conversion, map defaults, and pass-through of the raw schema.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Seeds.CatalogData

  @fixture Path.join([__DIR__, "../../support/fixtures/catalog_data_with_env_vars.yaml"])

  describe "entries/1" do
    test "shipped catalog_data.yaml normalizes the Forgejo entry (#71)" do
      entry = entry_by_slug("developer-tools")

      assert entry.category == %{
               name: "Developer Tools",
               slug: "developer-tools",
               description: "Source control and developer productivity apps."
             }

      assert [%{slug: "forgejo"} = app] = entry.apps
      assert app.name == "Forgejo"
      # #190: the toggle is deliberate per app — Forgejo ships without
      # (raw WebDAV into a git forge's data dir is a footgun), Kavita
      # ships with it (below).
      assert app.file_access == false

      version = hd(app.versions)
      assert version.version == "16.0.5"
      assert version.image == "codeberg.org/forgejo/forgejo:16.0.5"
      assert version.port == 3000
      assert version.healthcheck_path == "/api/healthz"
      assert version.storage_mount_path == "/data"
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 10
      assert version.recommended_size == "small"
      assert version.published_at == ~U[2026-09-17 15:27:32Z]

      assert version.default_env_vars["FORGEJO__database__DB_TYPE"] == "sqlite3"

      assert Map.has_key?(version.configurable_env_vars, "FORGEJO__mailer__SMTP_ADDR")

      # First-run contract passes through raw (string keys — #181);
      # the FirstRunContract type owns validation. Substrings, not
      # verbatim equality — copy edits must not break the loader test.
      assert version.first_run["pattern"] == "first_registered_user_admin"
      assert version.first_run["env"] == %{"FORGEJO__security__INSTALL_LOCK" => "true"}
      assert version.first_run["forbidden_env"] == ["FORGEJO__service__DISABLE_REGISTRATION"]

      guidance = version.first_run["guidance"]
      assert guidance =~ "first account becomes the admin"
      assert guidance =~ "close public sign-up"
    end

    test "shipped catalog_data.yaml normalizes the Kavita entry (#189)" do
      entry = entry_by_slug("media")

      assert entry.category == %{
               name: "Media & Entertainment",
               slug: "media",
               description: "Self-hosted media and reading servers for your own library."
             }

      assert [%{slug: "kavita"} = app] = entry.apps
      assert app.name == "Kavita"
      assert app.source_url == "https://github.com/Kareadita/Kavita"
      # #190: Kavita is the flagship file-access app — the toggle ships on
      assert app.file_access == true

      version = hd(app.versions)
      assert version.version == "0.9.1"
      # The canonical upstream image (its own release workflow), not a
      # re-published mirror.
      assert version.image == "ghcr.io/kareadita/kavita:0.9.1"
      assert version.port == 5000
      assert version.healthcheck_path == "/api/health"
      # Kavita's state lives under its working dir, not the volume root.
      assert version.storage_mount_path == "/kavita/config"
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 10
      assert version.recommended_size == "small"
      assert version.published_at == ~U[2026-09-02 21:07:38Z]

      # All config is in-app; no env surface at boot.
      assert version.default_env_vars == %{}
      assert version.configurable_env_vars == %{}

      # Register-first-admin, with no env keys to pin or lock.
      assert version.first_run["pattern"] == "first_registered_user_admin"
      assert version.first_run["env"] == %{}
      assert version.first_run["forbidden_env"] == []
      assert version.first_run["guidance"] =~ "first account becomes the admin"
    end

    test "comments-only and empty files parse to []" do
      comments_only = tmp_path("# comments only\n")
      assert CatalogData.entries(comments_only) == []

      empty = tmp_path("")
      assert CatalogData.entries(empty) == []
    end

    test "normalizes a full entry to atom-keyed maps" do
      [entry] = CatalogData.entries(@fixture)

      assert entry.category == %{name: "Test", slug: "test", description: "Test category"}

      assert [%{slug: "testapp"} = app] = entry.apps
      assert hd(app.versions).image == "test/image:1.0"
    end

    test "converts quoted-string cpu cores to Decimal and ISO 8601 to DateTime" do
      version = first_version(CatalogData.entries(@fixture))

      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 256
      assert version.default_storage_gb == 1
      assert version.published_at == ~U[2026-06-01 00:00:00Z]
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
                recommended_size: s
      """

      path = tmp_path(minimal_yaml)
      version = first_version(CatalogData.entries(path))

      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 256
      assert version.default_storage_gb == 0
      assert version.healthcheck_path == "/"
      assert version.published_at == nil
      assert version.default_env_vars == %{}
      assert version.configurable_env_vars == %{}
      assert version.first_run == nil
      assert version.storage_mount_path == "/data"
      assert version.recommended_size == "s"

      # #190: the toggle is optional and defaults off
      entry = hd(CatalogData.entries(path))
      assert hd(entry.apps).file_access == false
    end

    test "raises naming the version when recommended_size is missing (#125)" do
      unpriced_yaml = """
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

      assert_raise RuntimeError,
                   ~r/version "1.0.0" must name a recommended_size/,
                   fn ->
                     path = tmp_path(unpriced_yaml)
                     CatalogData.entries(path)
                   end
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
                  recommended_size: s
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

  # The shipped file carries multiple categories (#71's Forgejo, #189's
  # Kavita) — select by slug so adding an app never breaks these tests.
  defp entry_by_slug(slug) do
    default_catalog_path()
    |> CatalogData.entries()
    |> Enum.find(fn entry -> entry.category.slug == slug end)
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
