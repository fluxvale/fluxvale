defmodule FluxVale.Seeds.CatalogSeedTest do
  @moduledoc """
  The catalog seed flow (`FluxVale.Seeds.seed_catalog!/0`) against a
  sandboxed DB — the real helpers, not a fixture copy, so drift between
  loader and resources fails here.

  Idempotency assertions query by slug/version, not row counts, so they
  stay valid as the catalog grows.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Seeds

  describe "seed_catalog!/0" do
    test "creates the media category with the expected fields" do
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("media", authorize?: false)

      assert category.name == "Media & Entertainment"
      assert category.description =~ "media servers"
    end

    test "creates the Kavita app linked to the media category" do
      assert :ok == Seeds.seed_catalog!()

      category = Category.get_by_slug!("media", authorize?: false)
      app = App.get_by_slug!("kavita", authorize?: false)

      assert app.name == "Kavita"
      assert app.category_id == category.id
      assert app.tagline =~ "digital library"
      assert app.source_url == "https://github.com/Kareadita/Kavita"
      assert app.docs_url == "https://wiki.kavitareader.com"
    end

    test "creates the Kavita 0.9.0.2 AppVersion with deploy defaults" do
      assert :ok == Seeds.seed_catalog!()

      version = kavita_version!()

      assert version.version == "0.9.0.2"
      assert version.image == "jvmilazz0/kavita:0.9.0.2"
      assert version.port == 5000
      assert version.default_env_vars == %{}
      assert version.configurable_env_vars == %{}
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 512
      assert version.default_storage_gb == 5
      assert version.published_at == ~U[2026-05-14 14:04:05.000000Z]
    end

    test "seeds an env-var schema through the typed cast (structs in memory)" do
      {:ok, version} =
        seed_version_with_schema(%{
          "SMTP_HOST" => %{"label" => "SMTP Host", "type" => "string", "default" => ""},
          "SMTP_PORT" => %{"label" => "SMTP Port", "type" => "integer", "default" => 587}
        })

      assert %FluxVale.Catalog.Types.EnvVarSpec{} = version.configurable_env_vars["SMTP_HOST"]
      assert version.configurable_env_vars["SMTP_PORT"].default == 587
    end
  end

  describe "seed_catalog!/0 idempotency" do
    test "running twice produces no duplicate records" do
      assert :ok == Seeds.seed_catalog!()
      assert :ok == Seeds.seed_catalog!()

      assert Category.get_by_slug!("media", authorize?: false).slug == "media"
      assert App.get_by_slug!("kavita", authorize?: false).slug == "kavita"

      app =
        "kavita"
        |> App.get_by_slug!(authorize?: false)
        |> Ash.load!([:app_versions], authorize?: false)

      assert length(app.app_versions) == 1
      assert hd(app.app_versions).version == "0.9.0.2"
    end

    test "preserves the original published_at across re-runs" do
      assert :ok == Seeds.seed_catalog!()
      original = kavita_version!().published_at

      assert :ok == Seeds.seed_catalog!()

      assert kavita_version!().published_at == original
    end

    test "converges drifted data back to the YAML (update branch)" do
      assert :ok == Seeds.seed_catalog!()

      # Simulate stale data — re-seeding must overwrite it.
      version = kavita_version!()
      AppVersion.update!(version, %{image: "stale/image:old"}, authorize?: false)

      assert :ok == Seeds.seed_catalog!()

      assert kavita_version!().image == "jvmilazz0/kavita:0.9.0.2"
    end
  end

  # Fetches the single Kavita AppVersion; raises if there isn't exactly one.
  defp kavita_version! do
    "kavita"
    |> App.get_by_slug!(authorize?: false)
    |> Ash.load!([:app_versions], authorize?: false)
    |> Map.fetch!(:app_versions)
    |> hd()
  end

  # Seeds a version carrying a configurable_env_vars schema through the same
  # write path the YAML seed uses — the typed cast is exercised end-to-end.
  defp seed_version_with_schema(schema) do
    assert :ok == Seeds.seed_catalog!()

    app = App.get_by_slug!("kavita", authorize?: false)

    # Test precondition, mirroring the seed's bootstrap posture.
    AppVersion.create(
      %{
        version: "1.0.0-schema",
        image: "test/image:1.0",
        port: 8080,
        configurable_env_vars: schema,
        default_cpu_cores: Decimal.new("0.5"),
        default_memory_mb: 256,
        default_storage_gb: 1,
        published_at: ~U[2026-06-01 00:00:00.000000Z],
        app_id: app.id
      },
      authorize?: false
    )
  end
end
