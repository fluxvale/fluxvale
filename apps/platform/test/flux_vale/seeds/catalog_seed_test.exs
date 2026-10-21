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
  alias FluxVale.Pricing.Size
  alias FluxVale.Seeds
  alias FluxVale.Seeds.CatalogData

  @fixture Path.join([__DIR__, "../../support/fixtures/catalog_data_with_env_vars.yaml"])

  defp seed_fixture! do
    # The fixture version names `fixture-size` (0.5 / 256 / 1) — the seed
    # runner resolves the slug against a seeded row. Get-or-create: some
    # tests re-seed.
    case Size.get_by_slug("fixture-size", authorize?: false) do
      {:ok, _size} ->
        :ok

      {:error, _not_found} ->
        Size.create!(
          %{
            slug: "fixture-size",
            cpu_cores: Decimal.new("0.5"),
            memory_mb: 256,
            storage_gb: 1,
            monthly_cents: 100,
            stopped_monthly_cents: 10
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
      assert app.tagline == "Self-hosted Git forge with issues, pull requests, and Actions CI"

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
end
