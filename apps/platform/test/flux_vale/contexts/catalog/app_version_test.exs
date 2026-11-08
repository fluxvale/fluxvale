defmodule FluxVale.Catalog.AppVersionTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Catalog.Types.BackingService
  alias FluxVale.Catalog.Types.EnvVarSpec
  alias FluxVale.Catalog.Types.FirstRunContract
  alias FluxVale.Catalog.Types.OidcWiring
  alias FluxVale.Identity.User
  alias FluxVale.Pricing.Size

  defp app do
    n = System.unique_integer()

    category = Category.create!(%{name: "Cat #{n}", slug: "cat-#{n}"}, authorize?: false)

    App.create!(%{name: "App #{n}", slug: "app-#{n}", category_id: category.id},
      authorize?: false
    )
  end

  # Every version names a recommended_size whose compute equals the
  # version's cpu/memory defaults (the #125/#558 contract the
  # validations enforce) — the helper fabricates the matching size so
  # tests only speak in version attrs. default_storage_gb is the
  # version's own honest default, never pinned to the size.
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
          monthly_cents: 100
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
            default_memory_mb: 256
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

    test "bounds oidc_callback_path to a root-anchored URL path (#511)" do
      relative = version_attrs(app(), %{oidc_callback_path: "auth/callback"})
      spaces = version_attrs(app(), %{oidc_callback_path: "/a b"})

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(relative, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(spaces, authorize?: false)

      # The seed converges through the update action — the constraint
      # holds there too.
      attrs = version_attrs(app())
      version = AppVersion.create!(attrs, authorize?: false)

      rejected =
        AppVersion.update(version, %{oidc_callback_path: "auth/callback"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = rejected
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

    test "size must match the version's compute; storage is the version's own (#558)" do
      app = app()

      allocation = %{
        default_cpu_cores: Decimal.new("0.5"),
        default_memory_mb: 256,
        default_storage_gb: 1
      }

      compute_off = [
        # cpu off
        %{cpu_cores: Decimal.new("1"), memory_mb: 256},
        # memory off
        %{cpu_cores: Decimal.new("0.5"), memory_mb: 512}
      ]

      for size_shape <- compute_off do
        size = size_for!(allocation, size_shape)
        base = version_attrs(app, allocation)
        attrs = Map.put(base, :recommended_size_id, size.id)

        assert {:error, error} = AppVersion.create(attrs, authorize?: false)
        assert Exception.message(error) =~ "must match the version's compute defaults"
      end

      # A size states compute only, so any storage default fits it: the
      # decoupling means default_storage_gb prices per GB and never
      # forks the pin.
      matching_compute = size_for!(allocation)
      base = version_attrs(app, allocation)

      attrs =
        Map.merge(base, %{
          recommended_size_id: matching_compute.id,
          default_storage_gb: 50
        })

      assert {:ok, _version} = AppVersion.create(attrs, authorize?: false)
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
          default_memory_mb: 2048
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

      size = size_for!(Map.take(version, ~w(default_cpu_cores default_memory_mb)a))

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

  describe "first_run (typed by FirstRunContract, #181)" do
    test "defaults to nil and accepts a string-keyed contract" do
      plain_attrs = version_attrs(app())

      assert {:ok, plain} = AppVersion.create(plain_attrs, authorize?: false)
      assert plain.first_run == nil

      contract = %{
        "pattern" => "first_registered_user_admin",
        "env" => %{"APP__security__INSTALL_LOCK" => "true"},
        "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
        "guidance" => "Register first; you become admin."
      }

      attrs = version_attrs(app(), %{first_run: contract})
      assert {:ok, version} = AppVersion.create(attrs, authorize?: false)

      assert %FirstRunContract{} = version.first_run
      assert version.first_run.pattern == :first_registered_user_admin
    end

    test "round-trips through jsonb as a FirstRunContract struct" do
      attrs =
        version_attrs(app(), %{
          first_run: %{
            "pattern" => "first_registered_user_admin",
            "env" => %{"APP__security__INSTALL_LOCK" => "true"},
            "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
            "guidance" => "g"
          }
        })

      version = AppVersion.create!(attrs, authorize?: false)

      # Fresh read — cast_stored re-casts the jsonb map into the struct.
      assert {:ok, [reloaded]} = Ash.read(AppVersion, authorize?: false)
      assert reloaded.id == version.id
      assert %FirstRunContract{} = reloaded.first_run
      assert reloaded.first_run.env == %{"APP__security__INSTALL_LOCK" => "true"}
    end

    test "rejects a malformed contract at the resource boundary" do
      attrs =
        version_attrs(app(), %{
          first_run: %{"pattern" => "install_wizard", "guidance" => "g"}
        })

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "keeps the contract the sole owner of its keys (ValidateFirstRunEnv)" do
      contract = %{
        "pattern" => "first_registered_user_admin",
        "env" => %{"APP__security__INSTALL_LOCK" => "true"},
        "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
        "guidance" => "g"
      }

      # env key reappearing as an operator default
      overlapping_default =
        version_attrs(app(), %{
          first_run: contract,
          default_env_vars: %{"APP__security__INSTALL_LOCK" => "false"}
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(overlapping_default, authorize?: false)

      assert Enum.any?(errors, &(&1.message =~ "must not appear in default_env_vars"))

      # forbidden key reappearing as a deploy-time configurable
      overlapping_configurable =
        version_attrs(app(), %{
          first_run: contract,
          configurable_env_vars: %{
            "APP__service__DISABLE_REGISTRATION" => %{"label" => "x", "type" => "boolean"}
          }
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(overlapping_configurable, authorize?: false)

      assert Enum.any?(errors, &(&1.message =~ "must not appear in configurable_env_vars"))
    end

    test "the lock also holds on update — an AshAdmin edit cannot fork the layers" do
      base = version_attrs(app())
      version = AppVersion.create!(base, authorize?: false)

      contract = %{
        "pattern" => "first_registered_user_admin",
        "env" => %{},
        "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
        "guidance" => "g"
      }

      assert {:error, %Ash.Error.Invalid{}} =
               AppVersion.update(
                 version,
                 %{
                   first_run: contract,
                   configurable_env_vars: %{
                     "APP__service__DISABLE_REGISTRATION" => %{
                       "label" => "x",
                       "type" => "boolean"
                     }
                   }
                 },
                 authorize?: false
               )
    end

    test "case-variant spellings don't dodge the lock — consumers fold name case" do
      contract = %{
        "pattern" => "first_registered_user_admin",
        "env" => %{"APP__security__INSTALL_LOCK" => "true"},
        "forbidden_env" => ["APP__service__DISABLE_REGISTRATION"],
        "guidance" => "g"
      }

      case_variant_default =
        version_attrs(app(), %{
          first_run: contract,
          default_env_vars: %{"APP__Security__INSTALL_LOCK" => "false"}
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(case_variant_default, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message =~ "must not appear in default_env_vars" and
                   &1.message =~ "APP__Security__INSTALL_LOCK")
             )

      case_variant_configurable =
        version_attrs(app(), %{
          first_run: contract,
          configurable_env_vars: %{
            "APP__Service__DISABLE_REGISTRATION" => %{"label" => "x", "type" => "boolean"}
          }
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(case_variant_configurable, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message =~ "must not appear in configurable_env_vars" and
                   &1.message =~ "APP__Service__DISABLE_REGISTRATION")
             )
    end

    test "a contract key cannot hide in instance_url_env — the deployer applies it over the contract" do
      contract = %{
        "pattern" => "first_registered_user_admin",
        "env" => %{"APP__server__ROOT_URL" => "true"},
        "guidance" => "g"
      }

      attrs =
        version_attrs(app(), %{first_run: contract, instance_url_env: "APP__server__ROOT_URL"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(attrs, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message =~ "must not appear in instance_url_env" and
                   &1.message =~ "APP__server__ROOT_URL")
             )
    end
  end

  describe "oidc_wiring (typed by OidcWiring, #597)" do
    # The recipe names this version's declared SSO inputs — the
    # validation's contract. Shaped from the Vaultwarden seed.
    @sso_specs %{
      "SSO_AUTHORITY" => %{"label" => "Issuer", "type" => "string"},
      "SSO_CLIENT_ID" => %{"label" => "Client ID", "type" => "string"},
      "SSO_CLIENT_SECRET" => %{"label" => "Client secret", "type" => "string", "secret" => true},
      "SSO_ENABLED" => %{"label" => "Enabled", "type" => "boolean"}
    }

    @recipe %{
      "kind" => "env",
      "issuer_env" => "SSO_AUTHORITY",
      "client_id_env" => "SSO_CLIENT_ID",
      "client_secret_env" => "SSO_CLIENT_SECRET",
      "enabled_env" => "SSO_ENABLED",
      "pkce" => true
    }

    test "defaults to nil and accepts a string-keyed recipe naming declared inputs" do
      plain_attrs = version_attrs(app())

      assert {:ok, plain} = AppVersion.create(plain_attrs, authorize?: false)
      assert plain.oidc_wiring == nil

      attrs = version_attrs(app(), %{configurable_env_vars: @sso_specs, oidc_wiring: @recipe})

      assert {:ok, version} = AppVersion.create(attrs, authorize?: false)

      assert %OidcWiring{} = version.oidc_wiring
      assert version.oidc_wiring.kind == :env
      assert version.oidc_wiring.client_secret_env == "SSO_CLIENT_SECRET"
    end

    test "round-trips through jsonb as an OidcWiring struct" do
      attrs = version_attrs(app(), %{configurable_env_vars: @sso_specs, oidc_wiring: @recipe})
      version = AppVersion.create!(attrs, authorize?: false)

      # Fresh read — cast_stored re-casts the jsonb map into the struct.
      assert {:ok, [reloaded]} = Ash.read(AppVersion, authorize?: false)
      assert reloaded.id == version.id
      assert %OidcWiring{} = reloaded.oidc_wiring
      assert reloaded.oidc_wiring.enabled_env == "SSO_ENABLED"
      assert reloaded.oidc_wiring.pkce == true
    end

    test "rejects a malformed recipe at the resource boundary" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: @sso_specs,
          oidc_wiring: %{"kind" => "env", "issuer_env" => "SSO_AUTHORITY", "pkce" => true}
        })

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "a recipe naming an input the version never declares fails create, naming it" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: Map.delete(@sso_specs, "SSO_ENABLED"),
          oidc_wiring: @recipe
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(attrs, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message =~
                   "enabled_env \"SSO_ENABLED\" is not in this version's configurable_env_vars")
             )
    end

    test "the lock also holds on update — an AshAdmin edit cannot drift the recipe" do
      base = version_attrs(app())
      version = AppVersion.create!(base, authorize?: false)

      # Neither the recipe nor the specs may drift apart on update:
      # adding the recipe without declaring its inputs fails.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.update(version, %{oidc_wiring: @recipe}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message =~
                   "issuer_env \"SSO_AUTHORITY\" is not in this version's configurable_env_vars")
             )

      # And stripping a declared input out from under a live recipe
      # fails too.
      seeded_attrs =
        version_attrs(app(), %{configurable_env_vars: @sso_specs, oidc_wiring: @recipe})

      seeded =
        AppVersion.create!(
          seeded_attrs,
          authorize?: false
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.update(
                 seeded,
                 %{configurable_env_vars: Map.delete(@sso_specs, "SSO_CLIENT_ID")},
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.message =~
                   "client_id_env \"SSO_CLIENT_ID\" is not in this version's configurable_env_vars")
             )
    end

    test "the secret env must be secret-typed — a plain spec fails loudly" do
      plain_secret =
        Map.put(@sso_specs, "SSO_CLIENT_SECRET", %{
          "label" => "Client secret",
          "type" => "string"
        })

      attrs =
        version_attrs(app(), %{configurable_env_vars: plain_secret, oidc_wiring: @recipe})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(attrs, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message =~
                   "client_secret_env \"SSO_CLIENT_SECRET\" must name a secret-typed")
             )
    end

    test "a nil recipe skips the validation — wiring is opt-in per version (D4)" do
      # The SSO inputs can exist without a recipe (the manual #529
      # posture), and a version with neither is plain.
      attrs = version_attrs(app(), %{configurable_env_vars: @sso_specs})

      assert {:ok, _manual_only} = AppVersion.create(attrs, authorize?: false)
    end

    test "a recipe without enabled_env skips that one check — the toggle is optional" do
      # No SSO_ENABLED spec declared, none named: the remaining three
      # names still validate against the version's inputs.
      specs_sans_toggle = Map.delete(@sso_specs, "SSO_ENABLED")
      recipe_sans_toggle = Map.delete(@recipe, "enabled_env")

      attrs =
        version_attrs(app(), %{
          configurable_env_vars: specs_sans_toggle,
          oidc_wiring: recipe_sans_toggle
        })

      assert {:ok, version} = AppVersion.create(attrs, authorize?: false)
      assert version.oidc_wiring.enabled_env == nil
    end
  end

  # #612 (ADR-0045): the bundled backing-services declarations. The
  # pair mirrors the Docmost-class shape; majors come from the real
  # registry config so registry growth can't stale the suite.
  describe "backing_services (typed by BackingService, #612)" do
    @db_specs %{
      "DATABASE_URL" => %{
        "label" => "Database URL",
        "type" => "string",
        "secret" => true
      },
      "REDIS_URL" => %{"label" => "Redis URL", "type" => "string", "secret" => true}
    }

    defp registry_major(kind) do
      registry = Application.fetch_env!(:flux_vale, :backing_services)
      majors = Keyword.fetch!(registry, kind)
      hd(Map.keys(majors))
    end

    defp pair_attrs(specs \\ @db_specs) do
      version_attrs(app(), %{
        configurable_env_vars: specs,
        backing_services: [
          %{
            "kind" => "postgres",
            "version" => registry_major(:postgres),
            "url_env" => "DATABASE_URL"
          },
          %{"kind" => "redis", "version" => registry_major(:redis), "url_env" => "REDIS_URL"}
        ]
      })
    end

    # The collision arms' recipe side: SSO inputs the wiring names,
    # joined onto the db specs so both validators pass except for the
    # one-owner collision under test.
    defp sso_db_specs do
      Map.merge(@db_specs, %{
        "SSO_AUTHORITY" => %{"label" => "Issuer", "type" => "string"},
        "SSO_CLIENT_ID" => %{"label" => "Client ID", "type" => "string"}
      })
    end

    defp sso_recipe(secret_env) do
      %{
        "kind" => "env",
        "issuer_env" => "SSO_AUTHORITY",
        "client_id_env" => "SSO_CLIENT_ID",
        "client_secret_env" => secret_env,
        "pkce" => true
      }
    end

    defp assert_rejection(attrs, expected) do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.create(attrs, authorize?: false)

      assert Enum.any?(errors, &(&1.message =~ expected)),
             "expected an error mentioning #{inspect(expected)}, got: #{inspect(Enum.map(errors, & &1.message))}"
    end

    test "defaults to [] and accepts a valid postgres+redis pair against the real registry config" do
      plain_attrs = version_attrs(app())

      assert {:ok, plain} = AppVersion.create(plain_attrs, authorize?: false)
      assert plain.backing_services == []

      assert {:ok, version} = AppVersion.create(pair_attrs(), authorize?: false)

      assert [%BackingService{}, %BackingService{}] = version.backing_services
      assert Enum.map(version.backing_services, & &1.kind) == [:postgres, :redis]
    end

    test "round-trips through jsonb as BackingService structs" do
      version = AppVersion.create!(pair_attrs(), authorize?: false)

      # Fresh read — cast_stored re-casts each jsonb element.
      assert {:ok, [reloaded]} = Ash.read(AppVersion, authorize?: false)
      assert reloaded.id == version.id
      assert [%BackingService{} = postgres, %BackingService{} = redis] = reloaded.backing_services
      assert postgres.url_env == "DATABASE_URL"
      assert redis.kind == :redis
    end

    test "rejects a malformed declaration at the resource boundary" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: @db_specs,
          backing_services: [%{"kind" => "postgres", "url_env" => "DATABASE_URL"}]
        })

      assert {:error, %Ash.Error.Invalid{}} = AppVersion.create(attrs, authorize?: false)
    end

    test "a url_env the version never declares fails create, naming it" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: Map.delete(@db_specs, "REDIS_URL"),
          backing_services: [
            %{
              "kind" => "redis",
              "version" => registry_major(:redis),
              "url_env" => "REDIS_URL"
            }
          ]
        })

      assert_rejection(
        attrs,
        ~s(url_env "REDIS_URL" is not in this version's configurable_env_vars)
      )
    end

    test "a plain (non-secret) url_env spec fails loudly — the URL embeds the password" do
      plain =
        Map.put(@db_specs, "DATABASE_URL", %{"label" => "Database URL", "type" => "string"})

      assert_rejection(pair_attrs(plain), ~s(url_env "DATABASE_URL" must name a secret-typed))
    end

    test "a required url_env spec fails — the platform provides it" do
      forced =
        Map.put(@db_specs, "DATABASE_URL", %{
          "label" => "Database URL",
          "type" => "string",
          "secret" => true,
          "required" => true
        })

      assert_rejection(
        pair_attrs(forced),
        ~s(url_env "DATABASE_URL" must not be a required input)
      )
    end

    test "a url_env colliding with a first-run contract key fails, case-insensitively" do
      contract = %{
        "pattern" => "first_registered_user_admin",
        "env" => %{"database_url" => "postgres://external"},
        "guidance" => "g"
      }

      attrs = Map.put(pair_attrs(), :first_run, contract)

      assert_rejection(attrs, "url_env must not be a first-run contract key, got: database_url")
    end

    test "a url_env colliding with instance_url_env fails — the deployer owns that key" do
      attrs = Map.put(pair_attrs(), :instance_url_env, "DATABASE_URL")

      assert_rejection(attrs, ~s(url_env "DATABASE_URL" collides with instance_url_env))
    end

    test "a url_env colliding with host_allowlist_env fails — the deployer owns that key" do
      attrs = Map.put(pair_attrs(), :host_allowlist_env, "REDIS_URL")

      assert_rejection(attrs, ~s(url_env "REDIS_URL" collides with host_allowlist_env))
    end

    test "a url_env colliding with an oidc_wiring recipe env fails — the recipe owns that key" do
      base = pair_attrs(sso_db_specs())
      attrs = Map.put(base, :oidc_wiring, sso_recipe("DATABASE_URL"))

      assert_rejection(
        attrs,
        "url_env collides with the oidc_wiring recipe's client_secret_env (database_url)"
      )
    end

    test "case-variant recipe spellings don't dodge the lock" do
      base = pair_attrs(sso_db_specs())
      attrs = Map.put(base, :oidc_wiring, sso_recipe("database_url"))

      assert_rejection(
        attrs,
        "url_env collides with the oidc_wiring recipe's client_secret_env (database_url)"
      )
    end

    test "a recipe edit colliding with a stored declaration fails on update" do
      version = AppVersion.create!(pair_attrs(), authorize?: false)

      # The recipe arrives alone, the services sit in stored data —
      # the lock still fires because the validator reads both sides
      # of the changeset, whichever is edited.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.update(
                 version,
                 %{oidc_wiring: sso_recipe("REDIS_URL"), configurable_env_vars: sso_db_specs()},
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.message =~
                   "url_env collides with the oidc_wiring recipe's client_secret_env (redis_url)")
             )
    end

    test "duplicate kinds fail — at most one service per kind" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: Map.put(@db_specs, "PG_EXTRA_URL", @db_specs["REDIS_URL"]),
          backing_services: [
            %{
              "kind" => "postgres",
              "version" => registry_major(:postgres),
              "url_env" => "DATABASE_URL"
            },
            %{
              "kind" => "postgres",
              "version" => registry_major(:postgres),
              "url_env" => "PG_EXTRA_URL"
            }
          ]
        })

      assert_rejection(attrs, "at most one backing service per kind, duplicate: [:postgres]")
    end

    test "duplicate url_envs fail — one owner per key" do
      attrs =
        version_attrs(app(), %{
          configurable_env_vars: @db_specs,
          backing_services: [
            %{
              "kind" => "postgres",
              "version" => registry_major(:postgres),
              "url_env" => "REDIS_URL"
            },
            %{
              "kind" => "redis",
              "version" => registry_major(:redis),
              "url_env" => "REDIS_URL"
            }
          ]
        })

      assert_rejection(attrs, ~s(duplicate url_env ["redis_url"]))
    end

    test "case-variant duplicate url_envs fail too — the lock folds, like ValidateFirstRunEnv" do
      specs =
        @db_specs
        |> Map.put("PG_URL", @db_specs["DATABASE_URL"])
        |> Map.put("pg_url", @db_specs["DATABASE_URL"])

      attrs =
        version_attrs(app(), %{
          configurable_env_vars: specs,
          backing_services: [
            %{
              "kind" => "postgres",
              "version" => registry_major(:postgres),
              "url_env" => "PG_URL"
            },
            %{
              "kind" => "redis",
              "version" => registry_major(:redis),
              "url_env" => "pg_url"
            }
          ]
        })

      assert_rejection(attrs, ~s(duplicate url_env ["pg_url"]))
    end

    test "a major not in the platform registry fails, naming the approved majors" do
      unknown = Integer.to_string(String.to_integer(registry_major(:postgres)) + 1)

      attrs =
        version_attrs(app(), %{
          configurable_env_vars: @db_specs,
          backing_services: [
            %{"kind" => "postgres", "version" => unknown, "url_env" => "DATABASE_URL"}
          ]
        })

      assert_rejection(
        attrs,
        ~s(version #{inspect(unknown)} for kind :postgres is not in the platform backing-services registry)
      )
    end

    test "the registry itself holds a well-formed entry for every known kind (#612)" do
      # The config comment's load-bearing claims, made true by
      # construction: S2's quota math does Decimal.new/1 on cpu
      # (rejects floats — the backups stance) and reads port/memory_mb
      # as integers; image is an exact-tag pin, never :latest.
      registry = Application.fetch_env!(:flux_vale, :backing_services)

      for kind <- BackingService.known_kinds() do
        entries = Keyword.fetch!(registry, kind)
        assert Map.keys(entries) != [], "#{kind} registry has no majors"

        for {major, entry} <- entries do
          assert Regex.match?(~r/^\d+$/, major)
          assert is_binary(entry.image)
          assert entry.image =~ ":"
          refute entry.image =~ ":latest"

          assert is_integer(entry.port) and entry.port in 1..65_535
          assert is_binary(entry.cpu)
          assert {cpu, ""} = Decimal.parse(entry.cpu)
          assert Decimal.compare(cpu, Decimal.new(0)) == :gt
          assert is_integer(entry.memory_mb) and entry.memory_mb > 0
        end
      end
    end

    test "the lock also holds on update — an AshAdmin edit cannot drift a declaration" do
      version = AppVersion.create!(pair_attrs(), authorize?: false)

      # Stripping a declared input out from under a live declaration
      # fails, exactly like the create-time arm.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AppVersion.update(
                 version,
                 %{configurable_env_vars: Map.delete(@db_specs, "DATABASE_URL")},
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.message =~
                   ~s(url_env "DATABASE_URL" is not in this version's configurable_env_vars))
             )
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
