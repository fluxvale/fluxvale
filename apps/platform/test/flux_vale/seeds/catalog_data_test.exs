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

      # #511: the callback path pins the auth-source name the guide
      # tells the reader to use (the name is part of Forgejo's path).
      assert version.oidc_callback_path == "/user/oauth2/PocketID/callback"

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
               description: "Media and reading servers for your own library."
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
      # #511: the OIDC callback path — config is in-app, no env surface.
      assert version.oidc_callback_path == "/signin-oidc"
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

    # #492 gate: the admin panel is disabled in packaging. ADMIN_TOKEN
    # must not appear in ANY env layer — shipped defaults, deploy-time
    # settings, or a first-run contract's env (Vaultwarden ships no
    # contract at all). Compared downcased, so any casing fails the pin.
    test "Vaultwarden ships no ADMIN_TOKEN in any packaging layer (#492)" do
      version = vaultwarden_version()

      assert version.first_run == nil
      assert version.default_env_vars == %{}

      layer_keys =
        Map.keys(version.default_env_vars) ++
          Map.keys(version.configurable_env_vars)

      refute Enum.any?(layer_keys, &admin_token_key?/1)
    end

    test "shipped catalog_data.yaml normalizes the Vaultwarden entry (#492)" do
      entry = entry_by_slug("security")

      assert entry.category == %{
               name: "Security",
               slug: "security",
               description: "Password managers and other servers that hold secrets you control."
             }

      assert [%{slug: "vaultwarden"} = app] = entry.apps
      assert app.name == "Vaultwarden"
      assert app.source_url == "https://github.com/dani-garcia/vaultwarden"
      # #190: the toggle is deliberate per app — a password vault has no
      # file-library use case, so Vaultwarden ships without.
      assert app.file_access == false

      version = vaultwarden_version()
      assert version.version == "1.37.5"
      # The canonical upstream image (Docker Hub, the release workflow's
      # primary target), not a mirror.
      assert version.image == "docker.io/vaultwarden/server:1.37.5"
      assert version.port == 80
      # Upstream's own healthcheck path (the image HEALTHCHECK probes it).
      assert version.healthcheck_path == "/alive"
      # Vaultwarden's state IS the volume root (DATA_FOLDER defaults to
      # /data), so the loader default carries.
      assert version.storage_mount_path == "/data"
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.recommended_size == "micro"
      assert version.published_at == ~U[2026-11-01 22:16:50Z]

      # The instance's public URL rides the Forgejo-ROOT_URL mechanism.
      assert version.instance_url_env == "DOMAIN"

      # #511: the OIDC callback path, pinned from upstream's SSO wiki.
      assert version.oidc_callback_path == "/identity/connect/oidc-signin"

      # The sign-ups domain whitelist (the SIGNUPS_ALLOWED lockout
      # footgun is deliberately not shipped — see the YAML comment) and
      # the #511 SSO wiring. Raw pass-through here — string keys, the
      # EnvVarSchema type owns validation at write time.
      assert Map.has_key?(version.configurable_env_vars, "SIGNUPS_DOMAINS_WHITELIST")
      assert version.configurable_env_vars["SIGNUPS_DOMAINS_WHITELIST"]["type"] == "string"

      assert %{"type" => "boolean", "default" => false} =
               version.configurable_env_vars["SSO_ENABLED"]

      assert %{"type" => "string", "secret" => true} =
               version.configurable_env_vars["SSO_CLIENT_SECRET"]

      # #597: the automatic-wiring recipe passes through raw (string
      # keys); the OidcWiring type + ValidateOidcWiringEnv own
      # validation at write time. Pins the shipped shape — the seed
      # test asserts the typed struct this becomes.
      assert version.oidc_wiring == %{
               "kind" => "env",
               "issuer_env" => "SSO_AUTHORITY",
               "client_id_env" => "SSO_CLIENT_ID",
               "client_secret_env" => "SSO_CLIENT_SECRET",
               "enabled_env" => "SSO_ENABLED",
               "pkce" => true
             }
    end

    test "shipped catalog_data.yaml normalizes the Pocket ID entry (#492)" do
      entry = entry_by_slug("identity")

      assert entry.category == %{
               name: "Identity",
               slug: "identity",
               description: "Sign-in and identity apps that secure access to your other apps."
             }

      assert [%{slug: "pocket-id"} = app] = entry.apps
      assert app.name == "Pocket ID"
      assert app.source_url == "https://github.com/pocket-id/pocket-id"
      # Identity state is not file-ingest; the toggle ships off by default.
      assert app.file_access == false

      # #511: the honest-copy weight lives in the catalog description —
      # the instance is load-bearing, wants always-on, and the
      # encryption key is recovery material. Compared flattened: the
      # YAML hard-wraps.
      flat_description = String.replace(app.description, ~r/\s+/, " ")

      assert flat_description =~ "load-bearing"
      assert flat_description =~ "always-on"
      assert flat_description =~ "restoring a backup needs it"

      version = hd(app.versions)
      assert version.version == "2.19.2"
      # The canonical upstream image (its own release workflow), not a
      # re-published mirror.
      assert version.image == "ghcr.io/pocket-id/pocket-id:v2.19.2"
      assert version.port == 1411
      assert version.healthcheck_path == "/healthz"
      # All Pocket ID state (SQLite, uploads, GeoLite cache) resolves
      # under /app/data — the upstream compose volume's directory.
      assert version.storage_mount_path == "/app/data"
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.recommended_size == "micro"
      assert version.published_at == ~U[2026-11-02 20:18:20Z]

      # The instance URL rides the deploy op (passkeys bind to the
      # domain); TRUST_PROXY is operator posture (always behind Traefik).
      assert version.instance_url_env == "APP_URL"
      assert version.default_env_vars == %{"TRUST_PROXY" => "true"}

      # Raw pass-through at the loader level (string keys); the
      # EnvVarSchema type owns validation at write time. One required
      # secret input: the encryption key.
      assert %{"required" => true, "secret" => true, "type" => "string"} =
               version.configurable_env_vars["ENCRYPTION_KEY"]

      # #511: the input description states the recovery weight.
      assert version.configurable_env_vars["ENCRYPTION_KEY"]["description"] =~
               "restoring a backup"

      # Setup-page-first-admin, with no env keys to pin or lock.
      assert version.first_run["pattern"] == "first_registered_user_admin"
      assert version.first_run["env"] == %{}
      assert version.first_run["forbidden_env"] == []
      guidance = version.first_run["guidance"]
      assert guidance =~ "first account is the admin"
      assert guidance =~ "claim the instance promptly"
    end

    test "shipped catalog_data.yaml normalizes the ActualBudget entry (#492)" do
      entry = entry_by_slug("finance")

      assert entry.category == %{
               name: "Finance",
               slug: "finance",
               description: "Budgeting and money apps for the household."
             }

      assert [%{slug: "actualbudget"} = app] = entry.apps
      assert app.name == "ActualBudget"
      assert app.source_url == "https://github.com/actualbudget/actual"
      # A budget app's data dir is the app's own business — raw WebDAV
      # into financial records is a footgun (#190's per-app reasoning).
      assert app.file_access == false

      version = hd(app.versions)
      assert version.version == "26.11.0"
      # The canonical upstream image; ghcr and Docker Hub publish the
      # same build (identical amd64 digest).
      assert version.image == "ghcr.io/actualbudget/actual-server:26.11.0"
      assert version.port == 5006
      assert version.healthcheck_path == "/health"
      # /data is the image's default data dir — no mount override.
      assert version.storage_mount_path == "/data"
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 10
      assert version.recommended_size == "small"
      assert version.published_at == ~U[2026-11-02 01:54:02Z]

      # #511: the deploy op fills the server hostname (the OpenID
      # redirect target) and the wiring rides deploy-time inputs.
      assert version.instance_url_env == "ACTUAL_OPENID_SERVER_HOSTNAME"
      assert version.oidc_callback_path == "/openid/callback"

      assert version.default_env_vars == %{}

      # #521's contract is the sole owner of its keys: the two
      # bootstrap triggers ride forbidden_env and must not resurface as
      # deploy inputs — the seed validator refuses any overlap, so the
      # discovery URL is deliberately absent from the configurables.
      refute Map.has_key?(version.configurable_env_vars, "ACTUAL_OPENID_DISCOVERY_URL")

      assert %{"type" => "string", "secret" => true} =
               version.configurable_env_vars["ACTUAL_OPENID_CLIENT_SECRET"]

      # First open claims the server by setting the shared password
      # (ADR-0034 Am. 1) — nothing to pin; the lock exists for the
      # user-env injection path (#482), not shipped config.
      assert version.first_run["pattern"] == "first_open_sets_password"
      assert version.first_run["env"] == %{}

      assert version.first_run["forbidden_env"] == [
               "ACTUAL_OPENID_DISCOVERY_URL",
               "ACTUAL_OPENID_AUTHORIZATION_ENDPOINT"
             ]

      assert version.first_run["guidance"] =~ "set the server password"
    end

    test "shipped catalog_data.yaml normalizes the Memos entry (#492)" do
      entry = entry_by_slug("productivity")

      assert entry.category == %{
               name: "Productivity",
               slug: "productivity",
               description: "Notes and personal knowledge apps."
             }

      assert [%{slug: "memos"} = app] = entry.apps
      assert app.name == "Memos"
      assert app.source_url == "https://github.com/usememos/memos"
      # A note stream ingests nothing from outside — the toggle ships off
      assert app.file_access == false

      version = hd(app.versions)
      assert version.version == "26.11.0"
      # The canonical upstream image (its own release workflow), not a
      # re-published mirror.
      assert version.image == "ghcr.io/usememos/memos:26.11.0"
      assert version.port == 5230
      assert version.healthcheck_path == "/healthz"
      # Memos' state lives under its working dir (/var/opt/memos, the
      # image's own VOLUME), not the volume root.
      assert version.storage_mount_path == "/var/opt/memos"
      # #511: the OIDC callback path — config is in-app, Custom template.
      assert version.oidc_callback_path == "/auth/callback"
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.recommended_size == "micro"
      assert version.published_at == ~U[2026-11-01 14:04:41Z]

      # SQLite is the upstream default; no env surface at boot.
      assert version.default_env_vars == %{}
      assert version.configurable_env_vars == %{}

      # Register-first-host, with no env keys to pin or lock.
      assert version.first_run["pattern"] == "first_registered_user_admin"
      assert version.first_run["env"] == %{}
      assert version.first_run["forbidden_env"] == []
      assert version.first_run["guidance"] =~ "first account becomes the host"
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
      assert version.oidc_callback_path == nil
      assert version.oidc_wiring == nil
      assert version.backing_services == []
      assert version.recommended_size == "s"

      # #190: the toggle is optional and defaults off
      entry = hd(CatalogData.entries(path))
      assert hd(entry.apps).file_access == false
    end

    test "no shipped entry declares backing services — every version normalizes to [] (#612)" do
      versions =
        default_catalog_path()
        |> CatalogData.entries()
        |> Enum.flat_map(fn entry -> entry.apps end)
        |> Enum.flat_map(fn app -> app.versions end)

      assert versions != []
      assert Enum.all?(versions, &(&1.backing_services == []))
    end

    test "passes a backing-services declaration through raw for write-time validation (#612)" do
      db_yaml = """
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
                configurable_env_vars:
                  DATABASE_URL:
                    label: Database URL
                    type: string
                    secret: true
                backing_services:
                  - kind: postgres
                    version: "18"
                    url_env: DATABASE_URL
      """

      path = tmp_path(db_yaml)
      entries = CatalogData.entries(path)
      version = first_version(entries)
      # Raw pass-through (string keys); the BackingService type +
      # ValidateBackingServices own validation at write time.
      assert version.backing_services == [
               %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"}
             ]
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
  # Kavita, #492's Vaultwarden) — select by slug so adding an app never
  # breaks these tests.
  defp entry_by_slug(slug) do
    default_catalog_path()
    |> CatalogData.entries()
    |> Enum.find(fn entry -> entry.category.slug == slug end)
  end

  defp vaultwarden_version do
    "security"
    |> entry_by_slug()
    |> Map.fetch!(:apps)
    |> hd()
    |> Map.fetch!(:versions)
    |> hd()
  end

  # The #492 gate check: downcase-compared, so `admin_token`, `Admin_Token`
  # and friends all fail the pin (String.equivalent?/2 would not — it is
  # canonical equivalence, not case-folding).
  defp admin_token_key?(key), do: String.downcase(key) == "admin_token"

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
