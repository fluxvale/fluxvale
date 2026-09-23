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
  alias FluxVale.Seeds
  alias FluxVale.Seeds.CatalogData

  @fixture Path.join([__DIR__, "../../support/fixtures/catalog_data_with_env_vars.yaml"])

  defp seed_fixture! do
    entries = CatalogData.entries(@fixture)
    Seeds.seed_catalog!(entries)
  end

  describe "seed_catalog!/0 (shipped data)" do
    test "seeds the shipped Forgejo entry cleanly (#71)" do
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("developer-tools", authorize?: false)
      assert category.name == "Developer Tools"

      app = App.get_by_slug!("forgejo", authorize?: false)
      assert app.category_id == category.id
      assert app.tagline == "Self-hosted Git forge with issues, pull requests, and Actions CI"

      version = version_for!("forgejo")

      assert version.version == "16.0.5"
      assert version.image == "codeberg.org/forgejo/forgejo:16.0.5"
      assert version.port == 3000
      assert version.healthcheck_path == "/api/healthz"
      assert version.default_storage_gb == 10
      assert version.default_env_vars["FORGEJO__server__DISABLE_SSH"] == "true"
    end

    test "shipped env-var schema passes the typed cast (issue exit criterion)" do
      assert :ok == Seeds.seed_catalog!()

      version = version_for!("forgejo")

      assert %EnvVarSpec{} =
               version.configurable_env_vars["FORGEJO__service__DISABLE_REGISTRATION"]

      passwd = version.configurable_env_vars["FORGEJO__mailer__PASSWD"]
      assert passwd.type == :string
      assert passwd.secret == true

      smtp_port = version.configurable_env_vars["FORGEJO__mailer__SMTP_PORT"]
      assert smtp_port.type == :integer
      assert smtp_port.default == 587
    end

    test "re-seeding the shipped catalog converges without dupes" do
      assert :ok == Seeds.seed_catalog!()
      assert :ok == Seeds.seed_catalog!()

      app =
        "forgejo"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([:app_versions], authorize?: false)

      assert length(app.app_versions) == 1
      assert hd(app.app_versions).version == "16.0.5"
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
