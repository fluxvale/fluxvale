defmodule FluxVale.Infrastructure.InstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Catalog.Types.FirstRunContract
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  # Oban testing :inline runs trigger actions during the entry action —
  # the k8s surface is stubbed wherever a lifecycle action fires a job.
  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _data -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

    stub(Ingress, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Service, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Deployment, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Secret, :delete, fn _kc, _ns, _n -> :ok end)
    stub(PersistentVolumeClaim, :delete, fn _kc, _ns, _n -> :ok end)
    stub(NetworkPolicy, :delete, fn _kc, _ns, _n -> :ok end)
    stub(ResourceQuota, :delete, fn _kc, _ns, _n -> :ok end)
    stub(RoleBinding, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Namespace, :delete, fn _kc, _n -> :ok end)
  end

  defp user do
    User.create!("owner-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp forgejo_version do
    InstanceFixtures.app_version!(
      image: "codeberg.org/forgejo/forgejo:16.0.5",
      port: 3000,
      healthcheck_path: "/api/healthz",
      instance_url_env: "FORGEJO__server__ROOT_URL",
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 512,
      default_storage_gb: 10,
      # Production shape (#181): INSTALL_LOCK and the registration lock
      # live in the first-run contract, not the operator defaults.
      default_env_vars: %{
        "FORGEJO__database__DB_TYPE" => "sqlite3"
      },
      first_run: %{
        "pattern" => "first_registered_user_admin",
        "env" => %{"FORGEJO__security__INSTALL_LOCK" => "true"},
        "forbidden_env" => ["FORGEJO__service__DISABLE_REGISTRATION"],
        "guidance" => "Register first — the first account becomes admin."
      },
      configurable_env_vars: %{
        "FORGEJO__mailer__SMTP_PORT" => %{
          label: "SMTP port",
          type: :integer,
          default: 587,
          required: false,
          secret: false
        },
        "FORGEJO__mailer__ENABLED" => %{
          label: "Enable email",
          type: :boolean,
          default: false,
          required: true,
          secret: false
        }
      }
    )
  end

  # System status funnel for preconditions (mirrors the trigger ops).
  # System status funnel for preconditions (mirrors the trigger ops).
  defp status!(instance, status) do
    {:ok, updated} = InstanceK8s.update_status(instance, status, nil)
    updated
  end

  # Namespaced deployed states: namespace is write-once (the deploy
  # action owns it and the inline trigger races past :deploying) — pin
  # via seed after driving status through the funnel.
  defp deployed!(instance, status, namespace) do
    reached = status!(instance, status)
    InstanceFixtures.pin!(reached, namespace: namespace)
  end

  defp created!(attrs \\ %{}) do
    version = forgejo_version()
    InstanceFixtures.local_cluster!()

    base = %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}}
    attrs = Map.merge(base, Map.new(attrs))

    Instance.create!(attrs, actor: user())
  end

  describe "create/1 — blueprint snapshot" do
    test "snapshots the pricing triple — size, cents, and the 1-year clock together (#121)" do
      version = InstanceFixtures.app_version!(monthly_cents: 335, stopped_monthly_cents: 40)
      InstanceFixtures.local_cluster!()

      before = DateTime.utc_now()

      instance =
        Instance.create!(
          %{name: "Priced", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      after_create = DateTime.utc_now()

      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

      assert instance.size_id == size.id
      assert instance.grandfathered_monthly_cents == 335
      assert instance.grandfathered_stopped_monthly_cents == 40

      # The clock is one year from this create: bounded by year-shifted
      # timestamps captured either side of it.
      assert DateTime.compare(instance.grandfathered_until, DateTime.shift(before, year: 1)) ==
               :gt

      assert DateTime.compare(instance.grandfathered_until, DateTime.shift(after_create, year: 1)) ==
               :lt
    end

    test "a custom allocation snapshots the formula's cents with the same 1-year clock, no size (#186)" do
      version = InstanceFixtures.app_version!(monthly_cents: 335, stopped_monthly_cents: 40)
      InstanceFixtures.local_cluster!()

      before = DateTime.utc_now()

      instance =
        Instance.create!(
          %{
            name: "Custom priced",
            app_version_id: version.id,
            env_vars: %{},
            cpu_cores: Decimal.new("1"),
            memory_mb: 512,
            storage_gb: 10
          },
          actor: user()
        )

      after_create = DateTime.utc_now()

      # No size row — the anchor formula prices the allocation, and the
      # wizard shows exactly these cents (391/40 at 1 CPU / 512 MB /
      # 10 GB; the fabricated size price of 335 must NOT bleed in).
      assert instance.size_id == nil
      assert instance.grandfathered_monthly_cents == 391
      assert instance.grandfathered_stopped_monthly_cents == 40

      assert DateTime.compare(instance.grandfathered_until, DateTime.shift(before, year: 1)) ==
               :gt

      assert DateTime.compare(instance.grandfathered_until, DateTime.shift(after_create, year: 1)) ==
               :lt
    end

    test "a partial custom allocation snapshots the formula at the effective allocation (#186)" do
      # One cluster, one version (created! is single-shot).
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      # Only memory chosen: cpu/storage ride the version's defaults —
      # the allocation differs, so the formula prices the blend.
      instance =
        Instance.create!(
          %{
            name: "Partial custom",
            app_version_id: version.id,
            env_vars: %{},
            memory_mb: 1024
          },
          actor: user()
        )

      effective = %{
        cpu_cores: version.default_cpu_cores,
        memory_mb: 1024,
        storage_gb: version.default_storage_gb
      }

      rates = FluxVale.Pricing.price_allocation(effective)

      assert instance.size_id == nil
      assert instance.grandfathered_monthly_cents == rates.monthly_cents
      assert instance.grandfathered_stopped_monthly_cents == rates.stopped_monthly_cents
    end

    test "derives image/port/probes/resources from the AppVersion, pins owner + cluster" do
      instance = created!()

      assert instance.image == "codeberg.org/forgejo/forgejo:16.0.5"
      assert instance.port == 3000
      assert instance.healthcheck_path == "/api/healthz"
      assert instance.cpu_cores == Decimal.new("0.5")
      assert instance.memory_mb == 512
      assert instance.storage_gb == 10
      # The mount path snapshots from the version's blueprint (#189).
      assert instance.storage_mount_path == "/data"
      assert instance.cluster_id
      assert instance.organization_id
      assert instance.status == :pending
      assert instance.namespace == nil
      assert instance.running_since == nil
      assert instance.storage_metering_since == nil
    end

    test "snapshots the version's storage_mount_path (#189)" do
      version = InstanceFixtures.app_version!(storage_mount_path: "/kavita/config")
      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(
          %{name: "Kavita", app_version_id: version.id},
          actor: user()
        )

      # A Kavita-shaped version carries its state dir; a version that
      # omits it keeps the platform default.
      assert instance.storage_mount_path == "/kavita/config"

      default_version = InstanceFixtures.app_version!()
      default_instance = InstanceFixtures.instance!(default_version, user())

      assert default_instance.storage_mount_path == "/data"
    end

    # #190: the App's catalog toggle snapshots with the rest of the
    # blueprint — a later catalog edit never re-specs a running instance.
    test "snapshots the App's file_access flag (default off, on when declared)" do
      assert created!().file_access == false

      # created!/0 already pinned the single local cluster row
      version = InstanceFixtures.app_version!(file_access: true)

      instance =
        Instance.create!(
          %{name: "Files", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      assert instance.file_access == true
    end

    test "merges stringified defaults under user values (contract > user > operator > schema)" do
      instance =
        created!(env_vars: %{"FORGEJO__mailer__SMTP_PORT" => "2525", "USER_EXTRA" => "x"})

      # contract env — the guarantee, above every deploy-time layer
      assert instance.env_vars["FORGEJO__security__INSTALL_LOCK"] == "true"
      # operator defaults, stringified
      assert instance.env_vars["FORGEJO__database__DB_TYPE"] == "sqlite3"
      # schema defaults fill what the user omits
      assert instance.env_vars["FORGEJO__mailer__ENABLED"] == "false"
      # user values win over the layers below the contract
      assert instance.env_vars["FORGEJO__mailer__SMTP_PORT"] == "2525"
      assert instance.env_vars["USER_EXTRA"] == "x"
      # the forbidden key never ships — registration-open rides the
      # app's upstream default (#181)
      refute Map.has_key?(instance.env_vars, "FORGEJO__service__DISABLE_REGISTRATION")
    end

    test "rejects user values naming a contract key — loudly, both halves (#181)" do
      attrs = build_attrs()

      # The env half: the guaranteed posture is not a user setting.
      env_half = Map.put(attrs, :env_vars, %{"FORGEJO__security__INSTALL_LOCK" => "false"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(env_half, actor: user())

      assert Enum.any?(
               errors,
               &(&1.message =~ "first-run contract" and
                   &1.message =~ "FORGEJO__security__INSTALL_LOCK")
             )

      # The forbidden half: the #181 failure mode, closed at the seam.
      forbidden_half =
        Map.put(attrs, :env_vars, %{"FORGEJO__service__DISABLE_REGISTRATION" => "true"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(forbidden_half, actor: user())

      assert Enum.any?(
               errors,
               &(&1.message =~ "first-run contract" and
                   &1.message =~ "FORGEJO__service__DISABLE_REGISTRATION")
             )

      # Case-variant spelling of the forbidden key — Forgejo's
      # environment-to-ini lowercases ini sections, so the folded name
      # hits the same setting; the lock folds too (hostile-review
      # finding, #181).
      case_variant_half =
        Map.put(attrs, :env_vars, %{"FORGEJO__Service__DISABLE_REGISTRATION" => "true"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(case_variant_half, actor: user())

      assert Enum.any?(
               errors,
               &(&1.message =~ "first-run contract" and
                   &1.message =~ "FORGEJO__Service__DISABLE_REGISTRATION")
             )
    end

    test "holds the guarantee even for a drifted version (contract merges last, #181)" do
      # A state actions can't produce (ValidateFirstRunEnv rejects the
      # overlap at write time): a version whose operator default
      # contradicts its own contract — forced via seed, same posture
      # as InstanceFixtures.pin!.
      {:ok, contract} =
        FirstRunContract.new(%{
          "pattern" => "first_registered_user_admin",
          "env" => %{"APP__security__INSTALL_LOCK" => "true"},
          "guidance" => "g"
        })

      app = Ash.load!(forgejo_version(), :app, authorize?: false).app

      drifted =
        Ash.Seed.seed!(AppVersion, %{
          version: "9.9.9",
          image: "test/image:9.9",
          port: 3000,
          default_env_vars: %{"APP__security__INSTALL_LOCK" => "false"},
          first_run: contract,
          app_id: app.id
        })

      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(
          %{name: "Drifted", app_version_id: drifted.id, env_vars: %{}},
          actor: user()
        )

      assert instance.env_vars["APP__security__INSTALL_LOCK"] == "true"
    end

    test "generates a haikunate slug unique per cluster" do
      attrs = build_attrs()

      assert {:ok, first} = Instance.create(attrs, actor: user())
      assert {:ok, second} = Instance.create(attrs, actor: user())

      assert Regex.match?(~r/^[a-z]+-[a-z]+-\d{4}$/, first.slug)
      assert first.slug != second.slug
    end

    test "generate_unique_slug exhausts retries and assumes freedom without a cluster" do
      alias FluxVale.Infrastructure.Instance.GenerateSlug

      assert GenerateSlug.generate_unique_slug("some-cluster", 0) == {:error, :collision}
      assert {:ok, slug} = GenerateSlug.generate_unique_slug(nil)
      assert Regex.match?(~r/^[a-z]+-[a-z]+-\d{4}$/, slug)
    end

    defp build_attrs do
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}}
    end

    test "rejects schema-invalid env values" do
      # A version whose required var has no default — the only shape a
      # create can leave unmet (schema defaults auto-fill the rest).
      attrs = fn env ->
        version =
          InstanceFixtures.app_version!(
            configurable_env_vars: %{
              "APP_REQUIRED" => %{label: "Required", type: :string, required: true},
              "APP_INT" => %{label: "Int", type: :integer, default: 587},
              "APP_BOOL" => %{label: "Bool", type: :boolean, default: false}
            }
          )

        InstanceFixtures.local_cluster!()
        %{name: "My App", app_version_id: version.id, env_vars: env}
      end

      # required (no default) missing entirely
      missing = attrs.(%{"APP_INT" => "587"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(missing, actor: user())

      assert Enum.any?(errors, &(&1.message =~ "APP_REQUIRED is required"))

      # Empty strings count as missing (a Secret full of blanks serves no one).
      blank = attrs.(%{"APP_REQUIRED" => ""})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(blank, actor: user())

      assert Enum.any?(errors, &(&1.message =~ "APP_REQUIRED is required"))

      bad_int = attrs.(%{"APP_REQUIRED" => "x", "APP_INT" => "not-a-port"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(bad_int, actor: user())

      assert Enum.any?(errors, &(&1.message =~ "APP_INT must be a whole number"))

      bad_bool = attrs.(%{"APP_REQUIRED" => "x", "APP_BOOL" => "yes"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(bad_bool, actor: user())

      assert Enum.any?(errors, &(&1.message =~ ~s(APP_BOOL must be "true" or "false")))
    end

    test "rejects non-string env values (Secrets are strings)" do
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{
                   name: "My Forgejo",
                   app_version_id: version.id,
                   env_vars: %{"FORGEJO__mailer__ENABLED" => true}
                 },
                 actor: user()
               )

      assert Enum.any?(errors, &(&1.message =~ "all env var keys and values must be strings"))
    end

    test "a custom allocation on a sizeless version still prices by the formula (#186)" do
      # Ash.seed! — the only way to produce a sizeless AppVersion: the
      # create/update actions require a recommended_size (present
      # validations); pre-#125 drift rows look exactly like this.
      n = System.unique_integer()

      category =
        Category.create!(
          %{name: "Sizeless #{n}", slug: "sizeless-cat-#{n}", description: "test"},
          authorize?: false
        )

      app =
        App.create!(
          %{
            name: "Sizeless #{n}",
            slug: "sizeless-#{n}",
            tagline: "test",
            description: "test",
            category_id: category.id
          },
          authorize?: false
        )

      version =
        Ash.Seed.seed!(AppVersion, %{
          version: "1.0.0",
          image: "registry.example.com/app:1.0",
          port: 3000,
          default_cpu_cores: Decimal.new("0.5"),
          default_memory_mb: 512,
          default_storage_gb: 10,
          app_id: app.id
        })

      InstanceFixtures.local_cluster!()

      # Custom allocation: the formula needs no size — priced snapshot.
      custom =
        Instance.create!(
          %{
            name: "Custom on sizeless",
            app_version_id: version.id,
            env_vars: %{},
            cpu_cores: Decimal.new("1")
          },
          actor: user()
        )

      rates =
        FluxVale.Pricing.price_allocation(%{
          cpu_cores: Decimal.new("1"),
          memory_mb: 512,
          storage_gb: 10
        })

      assert custom.size_id == nil
      assert custom.grandfathered_monthly_cents == rates.monthly_cents

      # At the recommendation on the same version: unpriced (billing
      # never guesses a size it wasn't given).
      at_rec =
        Instance.create!(
          %{name: "At rec on sizeless", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      assert at_rec.size_id == nil
      assert at_rec.grandfathered_monthly_cents == nil
      assert at_rec.grandfathered_until == nil
    end

    test "requires a real app version" do
      InstanceFixtures.local_cluster!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{name: "My Forgejo", app_version_id: Ash.UUID.generate(), env_vars: %{}},
                 actor: user()
               )

      assert Enum.any?(errors, &(&1.message =~ "selected app version not found"))
    end

    test "cluster resolution fails loudly with zero or multiple clusters" do
      version = forgejo_version()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
                 actor: user()
               )

      assert Enum.any?(errors, &(&1.message =~ "no cluster is configured"))

      InstanceFixtures.local_cluster!()
      Cluster.create!(%{name: "second"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
                 actor: user()
               )

      assert Enum.any?(
               errors,
               &(&1.message =~ "cluster selection is not implemented for multiple clusters")
             )
    end

    test "requires a signed-in actor; the org is resolved from the actor" do
      # Ash 3 runs create policies after changes/validations — an actorless
      # create surfaces the organization_id presence error, not Forbidden;
      # it fails loudly either way and nothing is written.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(build_attrs())

      assert Enum.any?(errors, &(&1.field == :organization_id))
    end

    test "an actor without an org fails loudly (field-scoped, not a crash)" do
      # Ash.seed! — the only way to produce an org-less user: the create
      # action's JIT change always provisions one (state actions can't
      # produce, the documented seed! exception).
      orgless =
        Ash.Seed.seed!(User, %{
          email: "orgless-#{System.unique_integer()}@fluxvale.test"
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(build_attrs(), actor: orgless)

      assert Enum.any?(
               errors,
               &(&1.field == :organization_id and &1.message == "is required")
             )
    end
  end

  describe "create/1 — user-chosen allocation (#180)" do
    test "a chosen allocation wins over the version defaults, above or below the recommendation" do
      # One cluster, one version, two creates (created! is single-shot —
      # its second cluster row would trip multi-cluster resolution).
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      base = %{name: "Allocated", app_version_id: version.id, env_vars: %{}}

      above_attrs =
        Map.merge(base, %{cpu_cores: Decimal.new("2"), memory_mb: 2048, storage_gb: 40})

      above = Instance.create!(above_attrs, actor: user())

      assert above.cpu_cores == Decimal.new("2")
      assert above.memory_mb == 2048
      assert above.storage_gb == 40

      below_attrs =
        Map.merge(base, %{cpu_cores: Decimal.new("0.25"), memory_mb: 128, storage_gb: 2})

      below = Instance.create!(below_attrs, actor: user())

      assert below.cpu_cores == Decimal.new("0.25")
      assert below.memory_mb == 128
      assert below.storage_gb == 2
    end

    test "a partial choice takes the defaults for the untouched dimensions" do
      instance = created!(memory_mb: 1024)

      assert instance.cpu_cores == Decimal.new("0.5")
      assert instance.memory_mb == 1024
      assert instance.storage_gb == 10
    end

    test "the hard floors block regardless of choice (the recommendation is advisory, the floors are not)" do
      zero_cpu_attrs = Map.merge(build_attrs(), %{cpu_cores: Decimal.new("0")})

      assert {:error, %Ash.Error.Invalid{errors: cpu_errors}} =
               Instance.create(zero_cpu_attrs, actor: user())

      assert Enum.any?(cpu_errors, &(&1.field == :cpu_cores))

      zero_memory_attrs = Map.merge(build_attrs(), %{memory_mb: 0})

      assert {:error, %Ash.Error.Invalid{errors: memory_errors}} =
               Instance.create(zero_memory_attrs, actor: user())

      assert Enum.any?(memory_errors, &(&1.field == :memory_mb))

      negative_storage_attrs = Map.merge(build_attrs(), %{storage_gb: -1})

      assert {:error, %Ash.Error.Invalid{errors: storage_errors}} =
               Instance.create(negative_storage_attrs, actor: user())

      assert Enum.any?(storage_errors, &(&1.field == :storage_gb))
    end

    test "the ceilings fail validation instead of crashing the write (bigint encode bounds)" do
      huge_cpu_attrs = Map.merge(build_attrs(), %{cpu_cores: Decimal.new("1e30")})

      assert {:error, %Ash.Error.Invalid{errors: cpu_errors}} =
               Instance.create(huge_cpu_attrs, actor: user())

      assert Enum.any?(cpu_errors, &(&1.field == :cpu_cores))

      huge_memory_attrs = Map.merge(build_attrs(), %{memory_mb: 99_999_999_999_999_999_999})

      assert {:error, %Ash.Error.Invalid{errors: memory_errors}} =
               Instance.create(huge_memory_attrs, actor: user())

      assert Enum.any?(memory_errors, &(&1.field == :memory_mb))

      huge_storage_attrs = Map.merge(build_attrs(), %{storage_gb: 99_999_999})

      assert {:error, %Ash.Error.Invalid{errors: storage_errors}} =
               Instance.create(huge_storage_attrs, actor: user())

      assert Enum.any?(storage_errors, &(&1.field == :storage_gb))
    end
  end

  describe "policies" do
    test "owners read their instances; nobody else does" do
      owner = user()
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(
          %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      assert {:ok, _mine} = Instance.get_by_id(instance.id, actor: owner)

      # Read policies filter to nothing — the wrapped NotFound shape (v1's
      # known Ash behavior), indistinguishable from a nonexistent row.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Instance.get_by_id(instance.id, actor: user())
    end

    test "a non-member cannot drive lifecycle transitions or delete" do
      owner = user()
      instance = created_with_actor!(owner)
      stranger = user()

      # stop surfaces the pending-state validation before policy; deploy
      # and delete hit the policy (delete via the wrapped NotFound of the
      # authorized read inside the action)
      assert {:error, %Ash.Error.Invalid{}} = Instance.stop(instance, actor: stranger)

      assert {:error, %Ash.Error.Forbidden{}} = Instance.deploy(instance, actor: stranger)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Instance.delete(instance.id, actor: stranger)
    end

    test "list_for_actor scopes to the actor's org — no cross-org bleed" do
      owner = user()
      instance = created_with_actor!(owner)

      assert {:ok, listed} = Instance.list_for_actor(actor: owner)
      assert Enum.map(listed, & &1.id) == [instance.id]

      stranger = user()

      assert {:ok, []} = Instance.list_for_actor(actor: stranger)
    end
  end

  # created!/1 uses its own user; tests needing a SPECIFIC actor create here.
  defp created_with_actor!(actor) do
    version = forgejo_version()
    InstanceFixtures.local_cluster!()

    Instance.create!(
      %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
      actor: actor
    )
  end

  describe "update_status — state machine + anchors" do
    test "pending → deploying → starting → running; anchors land on :running" do
      instance = created!()

      deploying = status!(instance, :deploying)
      assert deploying.status == :deploying

      starting = status!(deploying, :starting)
      running = status!(starting, :running)

      assert running.running_since
      assert running.storage_metering_since == running.running_since
    end

    test "leaving :running folds the interval into the unbilled carry, keeps the storage anchor" do
      instance = created!()

      running =
        instance
        |> status!(:deploying)
        |> status!(:starting)
        |> status!(:running)

      stopped = status!(running, :stopped)

      # The interval's time is carried for settlement (#121) — as a
      # duration, so restart churn can never drop it — and the storage
      # anchor spans the stop (the PVC persists).
      assert stopped.running_since == nil
      assert stopped.unbilled_running_usec >= 0
      assert stopped.storage_metering_since == running.storage_metering_since

      restarted =
        stopped
        |> status!(:starting)
        |> status!(:running)

      # Storage billing spans the stop; a fresh running interval opens
      # on top of the still-pending carry (settle consumes both).
      assert restarted.storage_metering_since == running.storage_metering_since
      assert restarted.running_since
      assert DateTime.compare(restarted.running_since, running.running_since) == :gt
      assert restarted.unbilled_running_usec == stopped.unbilled_running_usec
    end

    test "rejects invalid transitions; :error and :deleting from anywhere" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :running, nil)

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :stopped, nil)

      assert {:ok, errored} = InstanceK8s.update_status(instance, :error, "boom")
      assert errored.status == :error

      assert {:ok, deleting} = InstanceK8s.update_status(instance, :deleting, nil)
      assert deleting.status == :deleting
    end

    # #196: the drain-on-lost guard — entering :lost parks every anchor
    # atomically with the status write, so a dead row stops accruing at
    # the detected moment (the incident's sin: billing for nothing).
    test "entering :lost parks every anchor and stamps lost_detected_at" do
      instance = created!()

      running =
        instance
        |> status!(:deploying)
        |> status!(:starting)
        |> status!(:running)

      lost = status!(running, :lost)

      assert lost.status == :lost
      assert lost.lost_detected_at
      assert is_nil(lost.running_since)
      assert lost.unbilled_running_usec == 0

      # The parked storage anchor is what stops the metering: both the
      # settle trigger's where and settle_fresh key on it.
      assert is_nil(lost.storage_metering_since)
    end

    test ":lost enters from the deployed states only; :deleting from :lost rides the any-state rule" do
      instance = created!()

      # pending has nothing to lose.
      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :lost, "gone")

      running =
        instance
        |> status!(:deploying)
        |> status!(:starting)
        |> status!(:running)

      stopped = status!(running, :stopped)
      lost = status!(stopped, :lost)
      assert lost.status == :lost

      # Teardown stays reachable from :lost (the owner's exit).
      assert {:ok, deleting} = InstanceK8s.update_status(lost, :deleting, nil)
      assert deleting.status == :deleting
    end

    # #203 (ADR-0036): the idle loop's own leg — sleeping folds like
    # stopped (storage-only billing by construction), wake re-enters
    # the start lane, and the idle clock resets on :running entry.
    test "running → sleeping folds the running anchor, keeps storage; wake re-enters starting" do
      instance = created!()

      running =
        instance
        |> status!(:deploying)
        |> status!(:starting)
        |> status!(:running)

      sleeping = status!(running, :sleeping)

      assert sleeping.status == :sleeping
      assert sleeping.running_since == nil
      assert sleeping.unbilled_running_usec >= 0
      assert sleeping.storage_metering_since == running.storage_metering_since

      waking = status!(sleeping, :starting)
      awake = status!(waking, :running)

      # Storage spans the sleep; the fresh interval opens on the carry.
      assert awake.storage_metering_since == running.storage_metering_since
      assert awake.running_since
      # The idle clock starts warm — a just-woken instance gets its
      # full idle window (the sweep can't re-sleep on a stale marker).
      assert awake.last_used_at
    end

    test ":sleeping enters from :running only — never mid-build, never from :stopped" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :sleeping, nil)

      stopped =
        instance
        |> status!(:deploying)
        |> status!(:starting)
        |> status!(:running)
        |> status!(:stopped)

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(stopped, :sleeping, nil)
    end
  end

  describe "deploy/1" do
    test "lands :deploying with the ADR-0005 namespace, then :starting via the inline trigger" do
      stub_k8s()
      instance = created!()

      {:ok, deploying} = Instance.deploy(instance, actor: owner_of(instance))

      assert deploying.status == :deploying
      assert deploying.namespace == "fluxvale-app-#{instance.id}"
      assert deploying.deployed_at

      # :inline runs the trigger during the action — re-fetch for the
      # post-trigger truth (v1 posture).
      {:ok, fresh} = Instance.get_by_id(instance.id, actor: owner_of(instance))
      assert fresh.status == :starting
      assert fresh.status_message =~ "awaiting readiness"
    end

    test "rejects deploy outside pending/error/lost" do
      created = created!()
      instance = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.deploy(instance, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot deploy instance in deploying"))
    end

    # #196: the re-deploy affordance — a :lost row re-enters the normal
    # deploy lane, the parked anchors re-seed on the next :running, and
    # lost_detected_at clears (the row is no longer describing a loss).
    test "re-deploys from :lost — fresh deploy, lost_detected_at cleared" do
      stub_k8s()
      created = created!()
      ns = "fluxvale-app-#{created.id}"

      lost =
        created
        |> deployed!(:deploying, ns)
        |> status!(:starting)
        |> status!(:running)
        |> status!(:lost)

      assert lost.lost_detected_at

      {:ok, deploying} = Instance.deploy(lost, actor: owner_of(created))

      assert deploying.status == :deploying
      assert deploying.namespace == ns

      # :inline runs the trigger during the action — re-fetch for the
      # post-trigger truth (v1 posture).
      {:ok, fresh} = Instance.get_by_id(created.id, actor: owner_of(created))
      assert fresh.status == :starting
      assert is_nil(fresh.lost_detected_at)

      # The fresh epoch re-seeds the parked storage anchor on :running.
      running = status!(fresh, :running)
      assert running.storage_metering_since
      assert running.running_since
    end
  end

  # The actor for follow-up lifecycle calls, re-derived from the record the
  # way the data model defines ownership: instance → organization → member.
  defp owner_of(instance) do
    org =
      instance
      |> Ash.load!(:organization, authorize?: false)
      |> Map.get(:organization)

    org
    |> Ash.load!(:members, authorize?: false)
    |> Map.get(:members)
    |> List.first()
  end

  describe "stop/1 and start/1" do
    test "stop scales to zero and lands :stopped; start scales back to :starting" do
      stub_k8s()

      created = created!()
      deploying = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      instance =
        deploying
        |> status!(:starting)
        |> status!(:running)

      expect(Deployment, :scale, fn _kc, ns, "app", 0 ->
        assert String.starts_with?(ns, "fluxvale-app-")
        {:ok, %{}}
      end)

      {:ok, stopped} = Instance.stop(instance, actor: owner_of(instance))
      assert stopped.status == :stopped

      expect(Deployment, :scale, fn _kc, _ns, "app", 1 -> {:ok, %{}} end)

      {:ok, started} = Instance.start(stopped, actor: owner_of(instance))
      assert started.status == :starting
    end

    test "stop/start guard their states" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.stop(instance, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot stop instance in pending"))

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.start(instance, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot start instance in pending"))
    end

    test "a failed scale lands :error with the reason" do
      stub_k8s()
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      created = created!()
      deploying = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      instance =
        deploying
        |> status!(:starting)
        |> status!(:running)

      expect(Deployment, :scale, fn _kc, _ns, _n, _r ->
        {:error, K8s.Error.connection_error("cluster unreachable")}
      end)

      {:ok, errored} = Instance.stop(instance, actor: owner_of(instance))
      assert errored.status == :error
      assert errored.status_message =~ "Stop failed: cluster unreachable"
    end
  end

  # #203 (ADR-0036): sleep is the platform's arm, touch is the beacon's
  # write, always-on is the owner's opt-out.
  describe "sleep/1, touch/1, set_always_on/1" do
    test "sleep scales to zero, flips the edge, lands :sleeping (system-only)" do
      stub_k8s()
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      created = created!()

      running =
        created
        |> deployed!(:deploying, "fluxvale-app-#{created.id}")
        |> status!(:starting)
        |> status!(:running)

      # System-only: the owner cannot fire it (the policy forbids).
      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.sleep(running, actor: owner_of(running))

      assert {:ok, sleeping} = Instance.sleep(running, authorize?: false)
      assert sleeping.status == :sleeping
    end

    test "sleep guards its state — only :running sleeps" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.sleep(instance, authorize?: false)

      assert Enum.any?(errors, &(&1.message =~ "cannot sleep instance in pending"))
    end

    test "touch writes the idle clock (system-only); start wakes a sleeping instance" do
      stub_k8s()

      created = created!()

      running =
        created
        |> deployed!(:deploying, "fluxvale-app-#{created.id}")
        |> status!(:starting)
        |> status!(:running)
        |> status!(:sleeping)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.touch(running, actor: owner_of(running))

      assert {:ok, touched} = Instance.touch(running, authorize?: false)
      assert touched.last_used_at

      expect(Deployment, :scale, fn _kc, _ns, "app", 1 -> {:ok, %{}} end)

      assert {:ok, waking} = Instance.start(running, actor: owner_of(running))
      assert waking.status == :starting
    end

    test "set_always_on is the member's toggle; a non-member is forbidden" do
      instance = created!()
      owner = owner_of(instance)

      assert {:ok, on} =
               Instance.set_always_on(instance, %{always_on: true}, actor: owner)

      assert on.always_on

      assert {:ok, off} =
               Instance.set_always_on(on, %{always_on: false}, actor: owner)

      refute off.always_on

      stranger =
        User.create!("stranger-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.set_always_on(off, %{always_on: true}, actor: stranger)
    end
  end

  describe "delete/1" do
    test "never-deployed rows hard-delete synchronously" do
      instance = created!()
      owner = owner_of(instance)

      assert {:ok, deleted} = Instance.delete(instance.id, actor: owner)
      assert deleted.id == instance.id

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, actor: owner)
    end

    test "deployed rows tear down asynchronously (inline) and hard-delete" do
      stub_k8s()

      created = created!()
      instance = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      owner = owner_of(created)

      expect(Namespace, :delete, fn _kc, ns ->
        assert ns == "fluxvale-app-#{instance.id}"
        :ok
      end)

      assert {:ok, deleting} = Instance.delete(instance.id, actor: owner)
      assert deleting.status == :deleting

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, actor: owner)
    end

    test "a row already :deleting is not re-enqueued" do
      stub_k8s()

      created = created!()
      instance = deployed!(created, :deleting, "fluxvale-app-#{created.id}")

      owner = owner_of(created)

      # Zero teardown deletes expected — the duplicate guard must hold.
      reject(Namespace, :delete, 2)

      assert {:ok, unchanged} = Instance.delete(instance.id, actor: owner)
      assert unchanged.status == :deleting
    end

    test "ownership is enforced by the authorized read inside" do
      instance = created!()

      assert {:error, _denied} = Instance.delete(instance.id, actor: user())
    end
  end

  describe "trigger actions" do
    test "perform_reconcile delegates to the reconciler (cron entry body)" do
      stub_k8s()

      created = created!()
      ns = "fluxvale-app-#{created.id}"

      instance =
        created
        |> status!(:deploying)
        |> status!(:starting)
        |> then(&InstanceFixtures.pin!(&1, namespace: ns))

      expect(Deployment, :status, fn _kc, _ns, "app" ->
        {:ok, %{replicas: 1, ready: 1, conditions: []}}
      end)

      {:ok, fresh} = Instance.get_by_id(instance.id, actor: owner_of(instance))

      fresh
      |> Ash.Changeset.for_update(:perform_reconcile, %{}, authorize?: false)
      |> Ash.update!()

      {:ok, reloaded} = Instance.get_by_id(instance.id, actor: owner_of(instance))
      assert reloaded.status == :running
    end

    test "mark_deploy_error lands :error for unexpected job failures" do
      instance = created!()

      instance
      |> Ash.Changeset.for_update(:mark_deploy_error, %{error: %{}}, authorize?: false)
      |> Ash.update!()
      |> then(fn updated ->
        assert updated.status == :error
        assert updated.status_message == "Deploy job failed unexpectedly"
        assert updated.failure_reason == :deploy_failed
      end)
    end

    test "mark_teardown_error lands :error with a retry hint" do
      instance = created!()

      instance
      |> Ash.Changeset.for_update(:mark_teardown_error, %{error: %{}}, authorize?: false)
      |> Ash.update!()
      |> then(fn updated ->
        assert updated.status == :error
        assert updated.status_message =~ "retry delete"
        assert updated.failure_reason == :teardown_failed
      end)
    end

    # #179: failure_reason is the friendly-copy classification — it
    # lands with :error writes and clears on recovery, so a retried
    # provision can never inherit the previous failure's copy.
    test "failure_reason lands on :error writes and clears on recovery" do
      instance = created!()
      deploying = InstanceFixtures.walk_to!(instance, :deploying)

      {:ok, errored} =
        InstanceK8s.update_status(deploying, :error, "Deploy failed: boom", :deploy_failed)

      assert errored.failure_reason == :deploy_failed

      # Recovery: deploy pins :deploying + clears the reason.
      {:ok, retrying} = Instance.deploy(errored, actor: owner_of(instance))
      assert retrying.status == :deploying
      assert is_nil(retrying.failure_reason)

      # And the funnel never leaves a stale reason on a non-error write.
      starting = InstanceFixtures.walk_to!(retrying, :starting)

      {:ok, running} = InstanceK8s.update_status(starting, :running, nil)

      assert is_nil(running.failure_reason)
    end
  end

  describe "validation callbacks" do
    test "StatusTransition and ValidateEnvVars callbacks" do
      alias FluxVale.Infrastructure.Instance.StatusTransition
      alias FluxVale.Infrastructure.Instance.ValidateEnvVars

      assert StatusTransition.atomic?() == false
      assert [message: st_message, vars: []] = StatusTransition.describe([])
      assert is_binary(st_message)

      assert ValidateEnvVars.atomic?() == false
      assert [message: ev_message, vars: []] = ValidateEnvVars.describe([])
      assert is_binary(ev_message)
    end
  end
end
