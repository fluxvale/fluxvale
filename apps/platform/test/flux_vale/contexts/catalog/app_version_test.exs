defmodule FluxVale.Catalog.AppVersionTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Catalog.Types.EnvVarSpec
  alias FluxVale.Identity.User
  alias FluxVale.Pricing.Size

  defp app do
    n = System.unique_integer()

    category = Category.create!(%{name: "Cat #{n}", slug: "cat-#{n}"}, authorize?: false)

    App.create!(%{name: "App #{n}", slug: "app-#{n}", category_id: category.id},
      authorize?: false
    )
  end

  # Every version names a recommended_size equal to its effective
  # allocation (the #125 contract the validations enforce) — the helper
  # fabricates the matching size so tests only speak in version attrs.
  defp version_attrs(app, overrides \\ %{}) do
    attrs =
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

    Map.put(attrs, :recommended_size_id, size_for!(attrs).id)
  end

  defp size_for!(attrs, overrides \\ %{}) do
    size_attrs =
      Map.merge(
        %{
          slug: "test-#{System.unique_integer()}",
          cpu_cores: attrs.default_cpu_cores,
          memory_mb: attrs.default_memory_mb,
          storage_gb: attrs.default_storage_gb,
          monthly_cents: 100,
          stopped_monthly_cents: 10
        },
        Map.new(overrides)
      )

    Size.create!(size_attrs, authorize?: false)
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
        app_id: app().id,
        # Must still match the resource defaults the action applies.
        recommended_size_id:
          size_for!(%{
            default_cpu_cores: Decimal.new("0.5"),
            default_memory_mb: 256,
            default_storage_gb: 0
          }).id
      }

      assert {:ok, version} = AppVersion.create(minimal, authorize?: false)

      assert Decimal.equal?(version.default_cpu_cores, Decimal.new("0.5"))
      assert version.default_memory_mb == 256
      assert version.default_storage_gb == 0
      assert version.healthcheck_path == "/"
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

    test "bounds healthcheck_path to a root-anchored URL path" do
      relative = version_attrs(app(), %{healthcheck_path: "api/healthz"})
      spaces = version_attrs(app(), %{healthcheck_path: "/a b"})

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(relative, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(spaces, authorize?: false)
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

  describe "recommended_size (#125)" do
    test "create requires a recommended_size" do
      attrs =
        app()
        |> version_attrs()
        |> Map.delete(:recommended_size_id)

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "update requires a recommended_size when the record lacks one" do
      # Pre-#125 row: only Ash.seed! can produce the nil-size state
      # (actions enforce the requirement).
      version = unsized_version!()

      assert {:error, %Ash.Error.Invalid{}} =
               AppVersion.update(version, %{image: "test/image:2.0"}, authorize?: false)
    end

    test "size must match the version's allocation" do
      app = app()

      allocation = %{
        default_cpu_cores: Decimal.new("0.5"),
        default_memory_mb: 256,
        default_storage_gb: 1
      }

      one_dimension_off = [
        # cpu off
        %{cpu_cores: Decimal.new("1"), memory_mb: 256, storage_gb: 1},
        # memory off
        %{cpu_cores: Decimal.new("0.5"), memory_mb: 512, storage_gb: 1},
        # storage off
        %{cpu_cores: Decimal.new("0.5"), memory_mb: 256, storage_gb: 50}
      ]

      for size_shape <- one_dimension_off do
        size = size_for!(allocation, size_shape)
        base = version_attrs(app, allocation)
        attrs = Map.put(base, :recommended_size_id, size.id)

        assert {:error, error} = AppVersion.create(attrs, authorize?: false)
        assert Exception.message(error) =~ "must match the version's allocation"
      end
    end

    test "updating allocation without the size fails (and the reverse)" do
      app = app()
      attrs = version_attrs(app)
      version = AppVersion.create!(attrs, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               AppVersion.update(version, %{default_memory_mb: 512}, authorize?: false)

      other =
        size_for!(%{
          default_cpu_cores: Decimal.new("1"),
          default_memory_mb: 2048,
          default_storage_gb: 20
        })

      assert {:error, %Ash.Error.Invalid{}} =
               AppVersion.update(version, %{recommended_size_id: other.id}, authorize?: false)
    end

    test "an unknown size id is the FK's error, not the validation's" do
      base = version_attrs(app())
      attrs = Map.put(base, :recommended_size_id, Ecto.UUID.generate())

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "converging a legacy nil-size row through the seed's update" do
      version = unsized_version!()

      size =
        size_for!(Map.take(version, ~w(default_cpu_cores default_memory_mb default_storage_gb)a))

      assert {:ok, updated} =
               AppVersion.update(version, %{recommended_size_id: size.id}, authorize?: false)

      assert updated.recommended_size_id == size.id
    end
  end

  # States actions can't produce (Ash.seed! sanction): the pre-#125
  # shape — a version row with no recommended_size.
  defp unsized_version! do
    Ash.Seed.seed!(AppVersion, %{
      version: "0.9.0",
      image: "test/image:0.9",
      port: 8080,
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 256,
      default_storage_gb: 1,
      app_id: app().id
    })
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
