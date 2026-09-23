defmodule FluxVale.Seeds.CatalogSeedTest do
  @moduledoc """
  The catalog seed flow (`FluxVale.Seeds.seed_catalog!/1`) against a
  sandboxed DB — the real helpers, not a fixture copy, so drift between
  loader and resources fails here.

  The shipped catalog_data.yaml is intentionally empty (until #71 lands
  Forgejo), so these drive the runner with fixture entries parsed by the
  same loader: `seed_catalog!/0` (the seeds.exs call) is exercised as the
  trivial no-op it currently is.

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
    test "empty shipped catalog seeds cleanly" do
      assert :ok == Seeds.seed_catalog!()
      assert {:ok, []} = Ash.read(Category, authorize?: false)
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

      version = fixture_version!()

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

      version = fixture_version!()

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
      original = fixture_version!().published_at

      assert :ok == seed_fixture!()

      assert fixture_version!().published_at == original
    end

    test "converges drifted AppVersion data back to the YAML (update branch)" do
      assert :ok == seed_fixture!()

      # Simulate stale data — re-seeding must overwrite it.
      version = fixture_version!()
      AppVersion.update!(version, %{image: "stale/image:old"}, authorize?: false)

      assert :ok == seed_fixture!()

      assert fixture_version!().image == "test/image:1.0"
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

  # Fetches the single fixture AppVersion; raises if there isn't exactly one.
  defp fixture_version! do
    "testapp"
    |> App.get_by_slug!(authorize?: false)
    |> Ash.load!([:app_versions], authorize?: false)
    |> Map.fetch!(:app_versions)
    |> hd()
  end
end
