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
               description: "Source control and developer productivity apps.",
               audience:
                 "A fit for teams that want their own source control and CI without running the servers."
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
               description: "Media and reading servers for your own library.",
               audience:
                 "A fit for personal libraries and households that want their own media server."
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
               description: "Password managers and other servers that hold secrets you control.",
               audience: "A fit for anyone who would rather hold their own passwords and keys."
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
               description: "Sign-in and identity apps that secure access to your other apps.",
               audience: "A fit for households and teams that want one sign-in they control."
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
               description: "Budgeting and money apps for the household.",
               audience: "A fit for households that want their budget data under their own roof."
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

      # #610 widened the category copy when Vikunja joined.
      assert entry.category == %{
               name: "Productivity",
               slug: "productivity",
               description: "Notes, tasks, and personal knowledge apps.",
               audience:
                 "A fit for people who want their notes and tasks in one place, on their own terms."
             }

      app = app_by_slug!([entry], "memos")
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

    # #610 gate: registration must stay open on a fresh instance, and
    # the registration toggle is the lockout footgun — setting it false
    # at deploy bricks a fresh install with no admin to undo it (no
    # OSS admin-grant path exists). The key must not appear in ANY env
    # layer. Compared downcased, so any casing fails the pin.
    test "Vikunja ships no ENABLEREGISTRATION in any packaging layer (#610)" do
      version = vikunja_version()

      assert version.first_run == nil

      layer_keys =
        Map.keys(version.default_env_vars) ++
          Map.keys(version.configurable_env_vars)

      refute Enum.any?(layer_keys, &enableregistration_key?/1)
    end

    test "shipped catalog_data.yaml normalizes the Vikunja entry (#610)" do
      entry = entry_by_slug("productivity")

      app = app_by_slug!([entry], "vikunja")
      assert app.name == "Vikunja"
      assert app.source_url == "https://github.com/go-vikunja/vikunja"
      # Tasks and attachments move through the app's own API — no
      # file-library use case, so the toggle ships off.
      assert app.file_access == false

      version = vikunja_version()
      assert version.version == "2.8.0"
      # The canonical upstream image (its own release pipeline pushes
      # GHCR); ghcr and Docker Hub publish the same build (identical
      # amd64 digest, verified 2026-11-08).
      assert version.image == "ghcr.io/go-vikunja/vikunja:2.8.0"
      assert version.port == 3456
      # `GET /health` answers 200 "OK" unauthenticated (verified from
      # the running 2.8.0 image).
      assert version.healthcheck_path == "/health"
      # The image presets the SQLite path /db/vikunja.db, so the PVC
      # lands at /db with files redirected under it.
      assert version.storage_mount_path == "/db"
      assert version.default_env_vars == %{"VIKUNJA_FILES_BASEPATH" => "/db/files"}
      # CORS builds its allowlist from service.publicurl — the deploy
      # op fills the instance's public URL (the ROOT_URL pattern).
      assert version.instance_url_env == "VIKUNJA_SERVICE_PUBLICURL"
      # #511: the OIDC callback path — the provider key `pocketid` is
      # pinned by the discrete env names, not the display-name input.
      assert version.oidc_callback_path == "/auth/openid/pocketid"
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.recommended_size == "micro"
      assert version.published_at == ~U[2026-11-05 20:44:21Z]

      # The session secret preserves sign-ins across restarts (the one
      # non-SSO input, optional and secret-shaped).
      secret = version.configurable_env_vars["VIKUNJA_SERVICE_SECRET"]
      assert %{"type" => "string", "secret" => true} = secret
      refute Map.has_key?(secret, "required")

      # #511: the discrete Pocket ID provider envs, inert while the
      # toggle stays false.
      assert %{"type" => "boolean", "default" => false} =
               version.configurable_env_vars["VIKUNJA_AUTH_OPENID_ENABLED"]

      assert %{"type" => "string", "default" => "Pocket ID"} =
               version.configurable_env_vars["VIKUNJA_AUTH_OPENID_PROVIDERS_POCKETID_NAME"]

      assert %{"type" => "string", "secret" => true} =
               version.configurable_env_vars[
                 "VIKUNJA_AUTH_OPENID_PROVIDERS_POCKETID_CLIENTSECRET"
               ]

      # #597: the second declared wiring recipe — pkce FALSE, unlike
      # Vaultwarden (Vikunja's OpenID client sends no code_challenge,
      # verified at v2.8.0). Raw pass-through here; the seed test
      # asserts the typed struct this becomes.
      assert version.oidc_wiring == %{
               "kind" => "env",
               "issuer_env" => "VIKUNJA_AUTH_OPENID_PROVIDERS_POCKETID_AUTHURL",
               "client_id_env" => "VIKUNJA_AUTH_OPENID_PROVIDERS_POCKETID_CLIENTID",
               "client_secret_env" => "VIKUNJA_AUTH_OPENID_PROVIDERS_POCKETID_CLIENTSECRET",
               "enabled_env" => "VIKUNJA_AUTH_OPENID_ENABLED",
               "pkce" => false
             }

      # The honest copy: registration open, first registrant not
      # admin, SQLite serialization — pinned so the facts can't drift.
      caveats = Enum.join(app.caveats, " ")
      assert caveats =~ "Sign-ups stay open"
      assert caveats =~ "not the admin"
      assert caveats =~ "SQLite"
    end

    test "shipped catalog_data.yaml normalizes the Umami entry (#576)" do
      entry = entry_by_slug("analytics")

      assert entry.category == %{
               name: "Analytics",
               slug: "analytics",
               description: "Web analytics and visitor insight apps for the sites you run.",
               audience:
                 "A fit for anyone who wants honest visitor numbers on the sites they run, without cookies or a third party holding the data."
             }

      assert [%{slug: "umami"} = app] = entry.apps
      assert app.name == "Umami"
      assert app.source_url == "https://github.com/umami-software/umami"
      # Analytics state is the owner's PostgreSQL, not files — the
      # toggle ships off.
      assert app.file_access == false

      version = hd(app.versions)
      assert version.version == "3.4.1"
      # The canonical upstream image; the tag carries no v prefix
      # (unlike Pocket ID — verified against the GHCR v2 API).
      assert version.image == "ghcr.io/umami-software/umami:3.4.1"
      assert version.port == 3000
      # The image's own HEALTHCHECK probes the same path.
      assert version.healthcheck_path == "/api/heartbeat"
      # Stateless: every row lives in the owner's PostgreSQL, so the
      # honest storage default is none at all (#558) — no PVC mounts.
      assert version.default_storage_gb == 0
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.recommended_size == "micro"
      assert version.published_at == ~U[2026-11-08 01:20:00Z]

      # No URL env and no OIDC consumer surface: Umami derives neither
      # from catalog data.
      assert version.instance_url_env == nil
      assert version.oidc_callback_path == nil

      # Nothing ships at boot — DATABASE_URL and APP_SECRET are the
      # owner's required inputs (the platform provisions no per-app
      # databases, OQ #14), and the optional 2FA key rides along.
      assert version.default_env_vars == %{}

      assert %{"required" => true, "secret" => true, "type" => "string"} =
               version.configurable_env_vars["DATABASE_URL"]

      assert %{"required" => true, "secret" => true, "type" => "string"} =
               version.configurable_env_vars["APP_SECRET"]

      two_factor = version.configurable_env_vars["TWO_FACTOR_ENCRYPTION_KEY"]
      assert %{"secret" => true, "type" => "string"} = two_factor
      # Optional: no `required` key rides the raw YAML (EnvVarSpec
      # defaults it to false at write time).
      refute Map.has_key?(two_factor, "required")

      # ADR-0034 Am. 2: upstream's migrations ship the fixed default
      # admin; the forbidden locks keep user env from skipping the
      # seeding migration.
      assert version.first_run["pattern"] == "default_admin_credentials"
      assert version.first_run["env"] == %{}
      assert version.first_run["forbidden_env"] == ["SKIP_DB_CHECK", "SKIP_DB_MIGRATION"]

      guidance = version.first_run["guidance"]
      assert guidance =~ "username admin and password umami"
      assert guidance =~ "Change that password right away"
    end

    test "shipped catalog_data.yaml normalizes the Docmost entry (#609)" do
      entry = entry_by_slug("knowledge")

      assert entry.category == %{
               name: "Knowledge",
               slug: "knowledge",
               description: "Wiki and knowledge base apps for teams that document together.",
               audience:
                 "A fit for teams that want their shared knowledge in one place they control."
             }

      assert [%{slug: "docmost"} = app] = entry.apps
      assert app.name == "Docmost"
      assert app.source_url == "https://github.com/docmost/docmost"
      # Uploads ride the app's own storage, not an owner-mounted
      # library — the file-access sidecar ships off.
      assert app.file_access == false

      version = hd(app.versions)
      assert version.version == "0.97.0"
      # Docker Hub only (GHCR has no docmost repository) and pinned by
      # tag AND the multi-arch index digest, verified against the
      # registry and a live pull.
      assert version.image ==
               "docker.io/docmost/docmost:0.97.0@sha256:40c454d74ffdd9ecb15833e4d96f3a630d59aad862a1869381ae6ee086454419"

      assert version.port == 3000
      # The dependency-aware endpoint: 200 only with the database and
      # Redis both up (verified live, including the hang-when-down
      # failure side).
      assert version.healthcheck_path == "/api/health"
      # Upstream's own VOLUME and compose mount.
      assert version.storage_mount_path == "/app/data/storage"
      # Uploads live on the instance volume — the honest default is
      # the small-app rung, not zero (Umami's stateless shape) and
      # not ten.
      assert version.default_storage_gb == 5
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 1024
      assert version.recommended_size == "medium"
      assert version.published_at == ~U[2026-11-09 02:00:00Z]

      # The deployer injects the instance URL (upstream defaults it to
      # localhost:3000, wrong for an instance).
      assert version.instance_url_env == "APP_URL"
      # Paid-tier SSO without a wiring recipe (#609's ruling): Docmost
      # derives no OIDC consumer surface from catalog data.
      assert version.oidc_callback_path == nil
      assert version.oidc_wiring == nil

      # The privacy default ships alone; everything else is the
      # owner's to bring (both backing services plus the app secret).
      assert version.default_env_vars == %{"DISABLE_TELEMETRY" => "true"}

      for name <- ["DATABASE_URL", "REDIS_URL", "APP_SECRET"] do
        assert %{"required" => true, "secret" => true, "type" => "string"} =
                 version.configurable_env_vars[name]
      end

      # ADR-0034: the setup page creates the workspace and the first
      # account (verified live: setup 200 then 403 forever); CLOUD is
      # locked because upstream's cloud mode short-circuits the
      # SetupGuard and would block the owner's claim (#181).
      assert version.first_run["pattern"] == "first_registered_user_admin"
      assert version.first_run["env"] == %{}
      assert version.first_run["forbidden_env"] == ["CLOUD"]

      guidance = version.first_run["guidance"]
      assert guidance =~ "create your account on the setup page"
      assert guidance =~ "becomes the workspace admin"
    end

    test "comments-only and empty files parse to []" do
      comments_only = tmp_path("# comments only\n")
      assert CatalogData.entries(comments_only) == []

      empty = tmp_path("")
      assert CatalogData.entries(empty) == []
    end

    # #611 S1 retro-fill: the eight shipped apps carry caveats and
    # alternatives promoted from facts already in the file, and every
    # category carries its audience line (plan §7.3, verbatim).
    test "shipped entries carry the marketing retro-fill (#611)" do
      entries = CatalogData.entries()

      audiences = Map.new(entries, &{&1.category.slug, &1.category.audience})

      assert audiences == %{
               "developer-tools" =>
                 "A fit for teams that want their own source control and CI without running the servers.",
               "media" =>
                 "A fit for personal libraries and households that want their own media server.",
               "productivity" =>
                 "A fit for people who want their notes and tasks in one place, on their own terms.",
               "security" =>
                 "A fit for anyone who would rather hold their own passwords and keys.",
               "identity" => "A fit for households and teams that want one sign-in they control.",
               "finance" =>
                 "A fit for households that want their budget data under their own roof.",
               "analytics" =>
                 "A fit for anyone who wants honest visitor numbers on the sites they run, without cookies or a third party holding the data.",
               "knowledge" =>
                 "A fit for teams that want their shared knowledge in one place they control."
             }

      for entry <- entries, app <- entry.apps do
        assert app.caveats != [], "#{app.slug} ships no caveats"
        assert app.alternatives != [], "#{app.slug} ships no alternatives"

        # Plan §7's copy rules hold on the curated prose: no em dashes,
        # no semicolons.
        for caveat <- app.caveats do
          refute String.contains?(caveat, ["\u2014", ";"]), "#{app.slug} caveat: #{caveat}"
        end
      end

      # Alternatives are names only (the plan's positioning pairs).
      assert app_by_slug!(entries, "forgejo").alternatives == ["GitHub", "GitLab"]
      assert app_by_slug!(entries, "kavita").alternatives == ["Komga", "Calibre-Web"]
      assert app_by_slug!(entries, "memos").alternatives == ["Google Keep", "Joplin"]
      assert app_by_slug!(entries, "vaultwarden").alternatives == ["Bitwarden", "1Password"]
      assert app_by_slug!(entries, "pocket-id").alternatives == ["Keycloak", "Auth0"]
      assert app_by_slug!(entries, "actualbudget").alternatives == ["YNAB", "Firefly III"]
      assert app_by_slug!(entries, "umami").alternatives == ["Plausible", "Matomo"]
      assert app_by_slug!(entries, "vikunja").alternatives == ["Todoist", "Trello"]
      assert app_by_slug!(entries, "docmost").alternatives == ["Notion", "Outline"]

      # S7 content, not S1: the typed lists stay absent on the shipped
      # entries ([]), the intros and community links nil.
      for entry <- entries, app <- entry.apps do
        assert app.screenshots == []
        assert app.features == []
        assert app.faq == []
        assert app.in_action_intro == nil
        assert app.community_url == nil
      end
    end

    test "first_run guidance carries no em dashes or semicolons anymore (D10)" do
      entries = CatalogData.entries()

      for entry <- entries,
          app <- entry.apps,
          guidance = get_in(app.versions, [Access.at(0), Access.key!(:first_run), "guidance"]),
          guidance != nil do
        refute String.contains?(guidance, "\u2014"), "#{app.slug} guidance still has an em dash"
        refute String.contains?(guidance, ";"), "#{app.slug} guidance still has a semicolon"
      end

      # The rewritten Forgejo/Kavita guidance keeps its meaning.
      forgejo = app_by_slug!(entries, "forgejo")
      forgejo_guidance = first_guidance(forgejo)
      assert forgejo_guidance =~ "first account becomes the admin"

      kavita = app_by_slug!(entries, "kavita")
      kavita_guidance = first_guidance(kavita)
      assert kavita_guidance =~ "file access over WebDAV provides"
    end

    test "the fixture's marketing fields pass through raw (string keys, #611)" do
      [entry] = CatalogData.entries(@fixture)

      assert entry.category.audience ==
               "A fit for fixture apps that prove the loader passes audience through."

      app = hd(entry.apps)

      assert app.caveats == [
               "Fixture caveat one, long enough for the twenty char floor.",
               "Fixture caveat two, also past the twenty char floor."
             ]

      assert app.alternatives == ["FixtureAlt", "OtherAlt"]
      assert app.in_action_intro == "A fixture intro line under the heading."
      assert app.community_url == "https://community.example.com"

      # Structured lists pass through with string keys — the types own
      # validation at write time (the first_run stance).
      assert app.screenshots == [
               %{
                 "src" => "/images/catalog/testapp/one.webp",
                 "alt" => "The fixture app's main screen",
                 "caption" => "The dashboard on first open"
               },
               %{
                 "src" => "/images/catalog/testapp/two.png",
                 "alt" => "The fixture app's settings screen"
               }
             ]

      assert app.features == [
               %{
                 "icon" => "hero-archive-box",
                 "title" => "Repositories",
                 "body" => "Host your own fixture repositories with full control."
               },
               %{
                 "icon" => "hero-bolt",
                 "title" => "Fast by default",
                 "body" => "The fixture app starts in well under a second every time."
               }
             ]

      assert app.faq == [
               %{
                 "question" => "Does the fixture app support SSH?",
                 "answer" => "No. The fixture app speaks HTTPS only, on every instance."
               }
             ]
    end

    test "normalizes a full entry to atom-keyed maps" do
      [entry] = CatalogData.entries(@fixture)

      assert entry.category == %{
               name: "Test",
               slug: "test",
               description: "Test category",
               audience: "A fit for fixture apps that prove the loader passes audience through."
             }

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

      # #611: the marketing fields default to their absent states —
      # lists [], strings nil, audience nil.
      app = hd(entry.apps)
      assert app.caveats == []
      assert app.alternatives == []
      assert app.in_action_intro == nil
      assert app.screenshots == []
      assert app.features == []
      assert app.faq == []
      assert app.community_url == nil
      assert entry.category.audience == nil
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

  defp app_by_slug!(entries, slug) do
    apps = Enum.flat_map(entries, & &1.apps)

    case Enum.find(apps, &(&1.slug == slug)) do
      nil -> raise "no seeded app named #{slug}"
      app -> app
    end
  end

  # The first version's guidance (nil when the app ships no contract).
  defp first_guidance(app) do
    case hd(app.versions).first_run do
      nil -> nil
      contract -> contract["guidance"]
    end
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

  # The #610 gate check: downcase-compared, so
  # `vikunja_service_enableregistration` in any casing fails the pin
  # (String.equivalent?/2 would not — it is canonical equivalence, not
  # case-folding).
  defp enableregistration_key?(key) do
    String.downcase(key) == "vikunja_service_enableregistration"
  end

  defp vikunja_version do
    entry = entry_by_slug("productivity")
    app = app_by_slug!([entry], "vikunja")
    hd(app.versions)
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
