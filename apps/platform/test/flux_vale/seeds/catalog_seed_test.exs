defmodule FluxVale.Seeds.CatalogSeedTest do
  @moduledoc """
  The catalog seed flow (`FluxVale.Seeds.seed_catalog!/1`) against a
  sandboxed DB — the real helpers, not a fixture copy, so drift between
  loader and resources fails here.

  `seed_catalog!/0` (the seeds.exs call) is covered against the shipped
  Forgejo entry (#71); the fixture-driven describes below cover the
  machinery's general shape (update-convergence branches, drift repair)
  beyond what one shipped entry exercises.

  Idempotency assertions query by slug/version, not row counts, so they
  stay valid as the catalog grows.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Catalog.Types.EnvVarSpec
  alias FluxVale.Catalog.Types.FirstRunContract
  alias FluxVale.Catalog.Types.OidcWiring
  alias FluxVale.Pricing.Size
  alias FluxVale.Seeds
  alias FluxVale.Seeds.CatalogData

  @fixture Path.join([__DIR__, "../../support/fixtures/catalog_data_with_env_vars.yaml"])

  defp seed_fixture! do
    # The fixture version names `fixture-size` (0.5 CPU / 256 MB — the
    # compute the pin requires, #558) — the seed runner resolves the
    # slug against a seeded row. Get-or-create: some tests re-seed.
    case Size.get_by_slug("fixture-size", authorize?: false) do
      {:ok, _size} ->
        :ok

      {:error, _not_found} ->
        Size.create!(
          %{
            slug: "fixture-size",
            cpu_cores: Decimal.new("0.5"),
            memory_mb: 256,
            monthly_cents: 100
          },
          authorize?: false
        )
    end

    entries = CatalogData.entries(@fixture)
    Seeds.seed_catalog!(entries)
  end

  describe "seed_catalog!/0 (shipped data)" do
    test "seeds the shipped Forgejo entry cleanly (#71)" do
      # Versions reference their priced size (#125) — pricing first.
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("developer-tools", authorize?: false)
      assert category.name == "Developer Tools"

      app = App.get_by_slug!("forgejo", authorize?: false)
      assert app.category_id == category.id
      assert app.tagline == "Git forge with issues, pull requests, and Actions CI"
      # #190: file access is deliberate per app — Forgejo ships without
      assert app.file_access == false

      version =
        "forgejo"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([app_versions: :recommended_size], authorize?: false)
        |> Map.fetch!(:app_versions)
        |> hd()

      assert version.version == "16.0.5"
      assert version.image == "codeberg.org/forgejo/forgejo:16.0.5"
      assert version.port == 3000
      assert version.healthcheck_path == "/api/healthz"
      assert version.default_storage_gb == 10
      assert version.default_env_vars["FORGEJO__server__DISABLE_SSH"] == "true"
      assert version.recommended_size.slug == "small"
    end

    test "seeds the Forgejo first-run contract (#181, ADR-0034)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      contract = version_for!("forgejo").first_run

      assert %FirstRunContract{} = contract
      assert contract.pattern == :first_registered_user_admin
      # INSTALL_LOCK moved from default_env_vars into the contract (its
      # one home); registration-open rides the upstream default plus
      # the forbidden lock, not a shipped value.
      assert contract.env == %{"FORGEJO__security__INSTALL_LOCK" => "true"}
      assert contract.forbidden_env == ["FORGEJO__service__DISABLE_REGISTRATION"]
      assert contract.guidance =~ "first account"

      version = version_for!("forgejo")
      assert version.default_env_vars["FORGEJO__security__INSTALL_LOCK"] == nil
      assert version.configurable_env_vars["FORGEJO__service__DISABLE_REGISTRATION"] == nil
    end

    test "shipped env-var schema passes the typed cast (issue exit criterion)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      version = version_for!("forgejo")

      # The sign-up toggle is gone from the deploy-time surface — the
      # contract owns that key now (asserted above).
      refute Map.has_key?(version.configurable_env_vars, "FORGEJO__service__DISABLE_REGISTRATION")

      passwd = version.configurable_env_vars["FORGEJO__mailer__PASSWD"]
      assert passwd.type == :string
      assert passwd.secret == true

      smtp_port = version.configurable_env_vars["FORGEJO__mailer__SMTP_PORT"]
      assert smtp_port.type == :integer
      assert smtp_port.default == 587
    end

    test "seeds the shipped Kavita entry and its first-run contract (#189)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("media", authorize?: false)
      assert category.name == "Media & Entertainment"

      app = App.get_by_slug!("kavita", authorize?: false)
      assert app.category_id == category.id
      assert app.source_url == "https://github.com/Kareadita/Kavita"
      # #190: Kavita ships with file access on
      assert app.file_access == true

      version = version_for!("kavita")
      assert version.version == "0.9.1"
      assert version.image == "ghcr.io/kareadita/kavita:0.9.1"
      assert version.port == 5000
      assert version.healthcheck_path == "/api/health"
      # The mount path is catalog data (#189): Kavita's state survives a
      # pod restart only when the PVC lands under its working dir.
      assert version.storage_mount_path == "/kavita/config"
      assert version.default_storage_gb == 10

      contract = version.first_run
      assert %FirstRunContract{} = contract
      assert contract.pattern == :first_registered_user_admin
      # Kavita has no env-shaped config surface — nothing to pin, nothing
      # to lock; the contract carries only the posture + guidance.
      assert contract.env == %{}
      assert contract.forbidden_env == []
      assert contract.guidance =~ "first account becomes the admin"
    end

    test "seeds the shipped Vaultwarden entry cleanly (#492)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("security", authorize?: false)
      assert category.name == "Security"

      app = App.get_by_slug!("vaultwarden", authorize?: false)
      assert app.category_id == category.id
      assert app.tagline == "Bitwarden-compatible password server for your own vault"
      assert app.file_access == false

      version =
        "vaultwarden"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([app_versions: :recommended_size], authorize?: false)
        |> Map.fetch!(:app_versions)
        |> hd()

      assert version.version == "1.37.5"
      assert version.image == "docker.io/vaultwarden/server:1.37.5"
      assert version.port == 80
      assert version.healthcheck_path == "/alive"
      # State on the volume root — the loader default carries.
      assert version.storage_mount_path == "/data"
      assert version.instance_url_env == "DOMAIN"
      # #511: the OIDC callback path lands in the DB row, pinned from
      # upstream's SSO wiki.
      assert version.oidc_callback_path == "/identity/connect/oidc-signin"
      assert version.default_env_vars == %{}
      assert version.first_run == nil
      # The compute class: micro (0.25 / 512, $2.59 at B′) plus the
      # version's own 5 GB storage default ($0.24 per-GB) — the
      # version compute defaults must equal the size's compute (#558)
      # (ValidateSizeMatchesAllocation enforces it at write time; this
      # asserts the shipped pairing).
      assert version.recommended_size.slug == "micro"

      # #492 gate, from DB rows: the admin panel stays disabled — no
      # ADMIN_TOKEN in any shipped layer, any casing (downcase-compared).
      layer_keys =
        Map.keys(version.default_env_vars) ++
          Map.keys(version.configurable_env_vars)

      refute Enum.any?(layer_keys, &admin_token_key?/1)

      # The single deploy-time setting casts through the typed schema.
      whitelist = version.configurable_env_vars["SIGNUPS_DOMAINS_WHITELIST"]
      assert %EnvVarSpec{} = whitelist
      assert whitelist.type == :string
      assert whitelist.secret != true

      # #511: the SSO wiring casts through the typed schema — the
      # toggle defaults off, the client secret rides as a secret.
      enabled = version.configurable_env_vars["SSO_ENABLED"]
      assert %EnvVarSpec{} = enabled
      assert enabled.type == :boolean
      assert enabled.default == false

      secret = version.configurable_env_vars["SSO_CLIENT_SECRET"]
      assert %EnvVarSpec{} = secret
      assert secret.type == :string
      assert secret.secret == true

      # #597: the wiring recipe lands typed on the row — presence =
      # this version offers automatic Pocket ID wiring, names ⊆ the
      # SSO_* inputs above (ValidateOidcWiringEnv enforced it).
      assert %OidcWiring{} = version.oidc_wiring
      assert version.oidc_wiring.kind == :env
      assert version.oidc_wiring.issuer_env == "SSO_AUTHORITY"
      assert version.oidc_wiring.client_id_env == "SSO_CLIENT_ID"
      assert version.oidc_wiring.client_secret_env == "SSO_CLIENT_SECRET"
      assert version.oidc_wiring.enabled_env == "SSO_ENABLED"
      assert version.oidc_wiring.pkce == true
    end

    test "seeds the shipped Pocket ID entry and its first-run contract (#492)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("identity", authorize?: false)
      assert category.name == "Identity"

      app = App.get_by_slug!("pocket-id", authorize?: false)
      assert app.category_id == category.id
      assert app.source_url == "https://github.com/pocket-id/pocket-id"

      version =
        "pocket-id"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([app_versions: :recommended_size], authorize?: false)
        |> Map.fetch!(:app_versions)
        |> hd()

      assert version.version == "2.19.2"
      assert version.image == "ghcr.io/pocket-id/pocket-id:v2.19.2"
      assert version.port == 1411
      assert version.healthcheck_path == "/healthz"
      # All Pocket ID state lives under /app/data (the upstream compose
      # volume); the entrypoint chowns it before dropping to PUID 1000.
      assert version.storage_mount_path == "/app/data"
      assert version.instance_url_env == "APP_URL"
      assert version.default_env_vars == %{"TRUST_PROXY" => "true"}
      # The featherweight compute, kept equal to `micro` by
      # ValidateSizeMatchesAllocation (the seed would refuse a drift).
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.recommended_size.slug == "micro"

      # The typed cast round-trips the one deploy-time input: a required
      # secret the owner generates (upstream's only hard boot gate).
      key = version.configurable_env_vars["ENCRYPTION_KEY"]
      assert %EnvVarSpec{} = key
      assert key.required == true
      assert key.secret == true
      assert key.type == :string
      assert is_nil(key.default)

      contract = version.first_run
      assert %FirstRunContract{} = contract
      assert contract.pattern == :first_registered_user_admin
      # Nothing to pin and nothing to lock: sign-ups default to disabled
      # in the admin UI, and /setup needs no env lever.
      assert contract.env == %{}
      assert contract.forbidden_env == []
      assert contract.guidance =~ "first account is the admin"
    end

    test "seeds the shipped ActualBudget entry and its first-run contract (#492)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("finance", authorize?: false)
      assert category.name == "Finance"

      app = App.get_by_slug!("actualbudget", authorize?: false)
      assert app.category_id == category.id
      assert app.tagline == "Envelope budgeting shared by the whole household"
      assert app.file_access == false

      version =
        "actualbudget"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([app_versions: :recommended_size], authorize?: false)
        |> Map.fetch!(:app_versions)
        |> hd()

      assert version.version == "26.11.0"
      assert version.image == "ghcr.io/actualbudget/actual-server:26.11.0"
      assert version.port == 5006
      assert version.healthcheck_path == "/health"
      assert version.storage_mount_path == "/data"
      assert version.default_storage_gb == 10
      # #511: the deploy op fills the server hostname (the OpenID
      # redirect target) and the callback path lands in the row.
      assert version.instance_url_env == "ACTUAL_OPENID_SERVER_HOSTNAME"
      assert version.oidc_callback_path == "/openid/callback"
      # The priced unit, pinned by slug like the sibling entries
      # (ValidateSizeMatchesAllocation enforces the pairing at write
      # time; this asserts the shipped one).
      assert version.recommended_size.slug == "small"

      # #511: the OpenID wiring casts through the typed schema — the
      # client secret rides as a secret.
      secret = version.configurable_env_vars["ACTUAL_OPENID_CLIENT_SECRET"]
      assert %EnvVarSpec{} = secret
      assert secret.type == :string
      assert secret.secret == true

      contract = version.first_run
      assert %FirstRunContract{} = contract
      assert contract.pattern == :first_open_sets_password
      # Nothing to pin; the lock is for the user-env injection path
      # (#482): the two upstream keys whose presence triggers the
      # boot-time OIDC self-claim bootstrap (ADR-0034 Am. 1).
      assert contract.env == %{}

      assert contract.forbidden_env == [
               "ACTUAL_OPENID_DISCOVERY_URL",
               "ACTUAL_OPENID_AUTHORIZATION_ENDPOINT"
             ]

      assert contract.guidance =~ "set the server password"
    end

    test "seeds the shipped Memos entry and its first-run contract (#492)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("productivity", authorize?: false)
      assert category.name == "Productivity"

      app = App.get_by_slug!("memos", authorize?: false)
      assert app.category_id == category.id
      assert app.source_url == "https://github.com/usememos/memos"
      # A note stream ingests nothing from outside; the toggle ships off.
      assert app.file_access == false

      version =
        "memos"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([app_versions: :recommended_size], authorize?: false)
        |> Map.fetch!(:app_versions)
        |> hd()

      assert version.version == "26.11.0"
      # The canonical upstream image (its own release workflow pushes
      # the same tags to Docker Hub and GHCR), not a mirror.
      assert version.image == "ghcr.io/usememos/memos:26.11.0"
      assert version.port == 5230
      # Upstream's ready endpoint (returns 200 "Service ready.").
      assert version.healthcheck_path == "/healthz"
      # The image's own VOLUME and working directory — the SQLite DB
      # only survives a pod restart when the PVC lands exactly there.
      assert version.storage_mount_path == "/var/opt/memos"
      # The featherweight compute, kept equal to `micro` by
      # ValidateSizeMatchesAllocation (the seed would refuse a drift).
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.recommended_size.slug == "micro"

      # SQLite is the upstream driver default; no env ships at boot.
      assert version.default_env_vars == %{}
      assert version.configurable_env_vars == %{}

      contract = version.first_run
      assert %FirstRunContract{} = contract
      assert contract.pattern == :first_registered_user_admin
      # Nothing to pin and nothing to lock: the first account becomes
      # the host, and closing sign-up afterwards is a stored instance
      # setting with no env override (upstream's tests pin registration
      # open as the default).
      assert contract.env == %{}
      assert contract.forbidden_env == []
      assert contract.guidance =~ "first account becomes the host"
    end

    test "seeds the shipped Umami entry and its first-run contract (#576)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("analytics", authorize?: false)
      assert category.name == "Analytics"

      app = App.get_by_slug!("umami", authorize?: false)
      assert app.category_id == category.id
      assert app.source_url == "https://github.com/umami-software/umami"
      # The state is the owner's PostgreSQL — no file-access sidecar.
      assert app.file_access == false

      version =
        "umami"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([app_versions: :recommended_size], authorize?: false)
        |> Map.fetch!(:app_versions)
        |> hd()

      assert version.version == "3.4.1"
      assert version.image == "ghcr.io/umami-software/umami:3.4.1"
      assert version.port == 3000
      # The image's own healthcheck path (unauthenticated 200 ok).
      assert version.healthcheck_path == "/api/heartbeat"
      # Stateless over an external database: zero storage, so the
      # deployer never mounts a PVC and the mount-path default is moot.
      assert version.default_storage_gb == 0
      # The compute class kept equal to `micro` by
      # ValidateSizeMatchesAllocation (the seed would refuse a drift).
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.25"))
      assert version.default_memory_mb == 512
      assert version.recommended_size.slug == "micro"

      # Nothing ships at boot; the owner supplies the database and the
      # secret at deploy time (required inputs, Pocket ID's shape).
      assert version.default_env_vars == %{}

      database_url = version.configurable_env_vars["DATABASE_URL"]
      assert %EnvVarSpec{} = database_url
      assert database_url.required == true
      assert database_url.secret == true

      app_secret = version.configurable_env_vars["APP_SECRET"]
      assert %EnvVarSpec{} = app_secret
      assert app_secret.required == true
      assert app_secret.secret == true

      two_factor = version.configurable_env_vars["TWO_FACTOR_ENCRYPTION_KEY"]
      assert %EnvVarSpec{} = two_factor
      assert two_factor.required == false
      assert two_factor.secret == true

      contract = version.first_run
      assert %FirstRunContract{} = contract
      assert contract.pattern == :default_admin_credentials
      # Nothing to pin; the locks keep user env from skipping the boot
      # migration that seeds the default admin (ADR-0034 Am. 2).
      assert contract.env == %{}
      assert contract.forbidden_env == ["SKIP_DB_CHECK", "SKIP_DB_MIGRATION"]
      assert contract.guidance =~ "username admin and password umami"
    end

    test "seeds the OIDC callback paths for the five consumers (#511)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      # The pinned values — Pocket ID is the provider, so its own row
      # carries no callback surface (nil).
      expected = %{
        "forgejo" => "/user/oauth2/PocketID/callback",
        "kavita" => "/signin-oidc",
        "vaultwarden" => "/identity/connect/oidc-signin",
        "actualbudget" => "/openid/callback",
        "memos" => "/auth/callback",
        "pocket-id" => nil
      }

      for {slug, path} <- expected do
        assert version_for!(slug).oidc_callback_path == path
      end
    end

    test "seeds the OIDC wiring recipe for Vaultwarden only (#597)" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()

      # D4: v1 wires Vaultwarden end to end; every other app — Pocket
      # ID included — carries no recipe (nil = no automatic wiring).
      expected = %{
        "vaultwarden" => %{kind: :env, pkce: true},
        "forgejo" => nil,
        "kavita" => nil,
        "actualbudget" => nil,
        "memos" => nil,
        "pocket-id" => nil
      }

      for {slug, recipe} <- expected do
        version = version_for!(slug)

        case recipe do
          nil ->
            assert version.oidc_wiring == nil

          shape ->
            assert %OidcWiring{} = version.oidc_wiring
            assert version.oidc_wiring.kind == shape.kind
            assert version.oidc_wiring.pkce == shape.pkce
        end
      end
    end

    test "re-seeding the shipped catalog converges without dupes" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_catalog!()
      assert :ok == Seeds.seed_catalog!()

      app =
        "forgejo"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([:app_versions], authorize?: false)

      assert length(app.app_versions) == 1
      assert hd(app.app_versions).version == "16.0.5"

      kavita =
        "kavita"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([:app_versions], authorize?: false)

      assert length(kavita.app_versions) == 1
      assert hd(kavita.app_versions).version == "0.9.1"

      pocket_id =
        "pocket-id"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([:app_versions], authorize?: false)

      assert length(pocket_id.app_versions) == 1
      assert hd(pocket_id.app_versions).version == "2.19.2"

      actualbudget =
        "actualbudget"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([:app_versions], authorize?: false)

      assert length(actualbudget.app_versions) == 1
      assert hd(actualbudget.app_versions).version == "26.11.0"

      # The recipe survives the second run (update-convergence carries
      # it — not just the create path), still typed.
      vaultwarden = version_for!("vaultwarden")
      assert %OidcWiring{} = vaultwarden.oidc_wiring
      assert vaultwarden.oidc_wiring.issuer_env == "SSO_AUTHORITY"
    end
  end

  describe "seed_catalog!/1 (fixture entries)" do
    test "creates the category with the expected fields" do
      assert :ok == seed_fixture!()

      category = Category.get_by_slug!("test", authorize?: false)

      assert category.name == "Test"
      assert category.description == "Test category"
    end

    test "creates the app linked to the category" do
      assert :ok == seed_fixture!()

      category = Category.get_by_slug!("test", authorize?: false)
      app = App.get_by_slug!("testapp", authorize?: false)

      assert app.name == "TestApp"
      assert app.category_id == category.id
      assert app.tagline == "Test app"
    end

    test "creates the AppVersion with deploy defaults" do
      assert :ok == seed_fixture!()

      version = version_for!("testapp")

      assert version.version == "1.0.0"
      assert version.image == "test/image:1.0"
      assert version.port == 8080
      assert version.default_env_vars == %{}
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 256
      assert version.default_storage_gb == 1
      assert version.published_at == ~U[2026-06-01 00:00:00.000000Z]
    end

    test "seeds the env-var schema through the typed cast (structs in memory)" do
      assert :ok == seed_fixture!()

      version = version_for!("testapp")

      assert %EnvVarSpec{} = version.configurable_env_vars["SMTP_HOST"]

      port = version.configurable_env_vars["SMTP_PORT"]
      assert port.default == 587
      assert port.type == :integer
    end

    test "seeds the first-run contract through the typed cast (#181)" do
      assert :ok == seed_fixture!()

      contract = version_for!("testapp").first_run

      assert %FirstRunContract{} = contract
      assert contract.pattern == :first_registered_user_admin
      assert contract.env == %{"APP__security__INSTALL_LOCK" => "true"}
      assert contract.forbidden_env == ["APP__service__DISABLE_REGISTRATION"]
      assert contract.guidance == "Register first; you become admin."
    end
  end

  describe "idempotency" do
    test "running twice produces no duplicate records" do
      assert :ok == seed_fixture!()
      assert :ok == seed_fixture!()

      assert Category.get_by_slug!("test", authorize?: false).slug == "test"

      app =
        "testapp"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([:app_versions], authorize?: false)

      assert length(app.app_versions) == 1
      assert hd(app.app_versions).version == "1.0.0"
    end

    test "preserves the original published_at across re-runs" do
      assert :ok == seed_fixture!()
      original = version_for!("testapp").published_at

      assert :ok == seed_fixture!()

      assert version_for!("testapp").published_at == original
    end

    test "converges drifted AppVersion data back to the YAML (update branch)" do
      assert :ok == seed_fixture!()

      # Simulate stale data — re-seeding must overwrite it.
      version = version_for!("testapp")
      AppVersion.update!(version, %{image: "stale/image:old"}, authorize?: false)

      assert :ok == seed_fixture!()

      assert version_for!("testapp").image == "test/image:1.0"
    end

    test "converges a dropped first-run contract back to the YAML (#181)" do
      assert :ok == seed_fixture!()

      version = version_for!("testapp")
      AppVersion.update!(version, %{first_run: nil}, authorize?: false)

      assert :ok == seed_fixture!()

      assert version_for!("testapp").first_run.pattern == :first_registered_user_admin
    end

    test "converges a drifted OIDC callback path back to the YAML (#511)" do
      assert :ok = seed_fixture!()

      # The fixture names no callback path, so the shipped shape is nil
      # — the same drift-to-nil the Pocket ID provider row exercises
      # against the shipped data.
      version = version_for!("testapp")
      AppVersion.update!(version, %{oidc_callback_path: "/stale/path"}, authorize?: false)

      assert :ok = seed_fixture!()

      assert version_for!("testapp").oidc_callback_path == nil
    end

    test "seeds a key-less version as [] and converges drifted declarations back to it (#612)" do
      assert :ok == seed_fixture!()

      # The fixture names no backing_services — the create branch lands
      # the resource default's [] (no shipped entry declares any yet).
      assert version_for!("testapp").backing_services == []

      # Drift through a VALID declaration (the update path validates it
      # for real — a secret, non-required, declared input).
      registry = Application.fetch_env!(:flux_vale, :backing_services)
      pg_entries = Keyword.fetch!(registry, :postgres)
      pg_major = hd(Map.keys(pg_entries))

      version = version_for!("testapp")

      AppVersion.update!(
        version,
        %{
          backing_services: [
            %{"kind" => "postgres", "version" => pg_major, "url_env" => "SMTP_PASSWORD"}
          ]
        },
        authorize?: false
      )

      assert :ok == seed_fixture!()

      assert version_for!("testapp").backing_services == []
    end

    test "converges drifted category and app data too (symmetric convergence)" do
      assert :ok == seed_fixture!()

      category = Category.get_by_slug!("test", authorize?: false)
      Ash.update!(category, %{description: "stale"}, authorize?: false)

      app = App.get_by_slug!("testapp", authorize?: false)
      Ash.update!(app, %{tagline: "stale"}, authorize?: false)

      assert :ok == seed_fixture!()

      assert Category.get_by_slug!("test", authorize?: false).description == "Test category"
      assert App.get_by_slug!("testapp", authorize?: false).tagline == "Test app"
    end

    test "heals a legacy nil-size version on re-seed (#125)" do
      assert :ok == seed_fixture!()

      version = version_for!("testapp")

      # States neither actions (the validations reject it) nor Ash.Seed
      # (create-only; the identity blocks a duplicate row) can produce:
      # the pre-#125 shape — an existing row with its size detached.
      # Forced precondition, same posture as InstanceFixtures.pin!.
      detach =
        from(v in AppVersion,
          where: v.id == ^version.id,
          update: [set: [recommended_size_id: nil]]
        )

      {1, _result} = Repo.update_all(detach, [])

      assert :ok == seed_fixture!()

      healed =
        "testapp"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([app_versions: :recommended_size], authorize?: false)
        |> Map.fetch!(:app_versions)
        |> hd()

      assert healed.recommended_size.slug == "fixture-size"
    end
  end

  describe "recommended-size resolution (#125)" do
    test "raises naming the slug when the version references an unknown size" do
      entries = CatalogData.entries(@fixture)

      assert_raise RuntimeError,
                   ~r/unknown pricing size "fixture-size".*seed_pricing!/,
                   fn -> Seeds.seed_catalog!(entries) end
    end
  end

  # Fetches the single AppVersion for an app slug; raises if there isn't
  # exactly one.
  defp version_for!(slug) do
    slug
    |> App.get_by_slug!(authorize?: false)
    |> Ash.load!([:app_versions], authorize?: false)
    |> Map.fetch!(:app_versions)
    |> hd()
  end

  # The #492 gate check: downcase-compared, so any casing fails the pin
  # (String.equivalent?/2 would not — it is canonical equivalence, not
  # case-folding).
  defp admin_token_key?(key), do: String.downcase(key) == "admin_token"
end
