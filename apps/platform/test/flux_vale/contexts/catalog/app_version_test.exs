defmodule FluxVale.Catalog.AppVersionTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Catalog.Types.EnvVarSpec
  alias FluxVale.Identity.User

  defp app do
    n = System.unique_integer()

    category = Category.create!(%{name: "Cat #{n}", slug: "cat-#{n}"}, authorize?: false)

    App.create!(%{name: "App #{n}", slug: "app-#{n}", category_id: category.id},
      authorize?: false
    )
  end

  defp version_attrs(app, overrides \\ %{}) do
    Map.merge(
      %{
        version: "1.0.0",
        image: "test/image:1.0",
        port: 8080,
        default_cpu_cores: Decimal.new("0.5"),
        default_memory_mb: 256,
        default_storage_gb: 1,
        app_id: app.id
      },
      overrides
    )
  end

  describe "create/2" do
    test "fills deploy defaults and accepts the blueprint" do
      attrs = version_attrs(app())

      assert {:ok, version} = AppVersion.create(attrs, authorize?: false)

      assert version.version == "1.0.0"
      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 256
      assert version.default_storage_gb == 1
      assert version.published_at == nil
    end

    test "applies resource defaults when the blueprint omits them" do
      minimal = %{
        version: "2.0.0",
        image: "test/image:2.0",
        port: 8080,
        app_id: app().id
      }

      assert {:ok, version} = AppVersion.create(minimal, authorize?: false)

      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 256
      assert version.default_storage_gb == 0
      assert version.default_env_vars == %{}
      assert version.configurable_env_vars == %{}
    end

    test "bounds port to 1..65535" do
      app = app()
      low = version_attrs(app, %{port: 0})
      high = version_attrs(app, %{port: 65_536})

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(low, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(high, authorize?: false)
    end

    test "enforces unique version per app" do
      attrs = version_attrs(app())
      AppVersion.create!(attrs, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)

      same_version_elsewhere = version_attrs(app(), %{version: "1.0.0"})

      assert {:ok, _other_app} =
               AppVersion.create(same_version_elsewhere, authorize?: false)
    end

    test "freezes version after create — the seed's lookup key, like slug" do
      attrs = version_attrs(app())
      version = AppVersion.create!(attrs, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(version, %{version: "9.9.9"}, authorize?: false)
    end
  end

  describe "configurable_env_vars (typed by EnvVarSchema)" do
    test "rejects unknown spec fields at the resource boundary" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: %{"SMTP_HOST" => %{"labl" => "x", "type" => "string"}}
        })

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "rejects a default that contradicts the declared type" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: %{
            "SMTP_PORT" => %{"label" => "Port", "type" => "integer", "default" => "587"}
          }
        })

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "rejects malformed env-var names" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: %{"SMTP-HOST" => %{"label" => "Host", "type" => "string"}}
        })

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "round-trips through jsonb as EnvVarSpec structs" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: %{
            "SMTP_HOST" => %{"label" => "SMTP Host", "type" => "string", "default" => ""},
            "SMTP_PORT" => %{"label" => "SMTP Port", "type" => "integer", "default" => 587}
          }
        })

      version = AppVersion.create!(attrs, authorize?: false)

      # Fresh read — cast_stored re-validates the jsonb shape into structs.
      assert {:ok, [reloaded]} = Ash.read(AppVersion, authorize?: false)
      assert reloaded.id == version.id
      assert %EnvVarSpec{} = reloaded.configurable_env_vars["SMTP_HOST"]

      port = reloaded.configurable_env_vars["SMTP_PORT"]
      assert port.default == 587
      assert port.type == :integer
    end
  end

  describe "policy" do
    test "any signed-in actor reads; non-admins cannot mutate" do
      attrs = version_attrs(app())
      version = AppVersion.create!(attrs, authorize?: false)

      suffix = System.unique_integer()
      regular = User.create!("regular-#{suffix}@fluxvale.com", %{}, authorize?: false)

      assert {:ok, [_row]} = Ash.read(AppVersion, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(version, %{image: "nope"}, actor: regular, authorize?: true)
    end
  end
end
